// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IParallelPool } from "./interfaces/IParallelPool.sol";
import { IBondRegistry } from "./interfaces/IBondRegistry.sol";
import { IFlashAccessCallback } from "./interfaces/IFlashAccessCallback.sol";
import { LaneVault } from "./LaneVault.sol";

/// @title ParallelPool
/// @notice Shared liquidity pool with flash access for parallel EVMs.
/// @dev Liquidity is split across N **lane vaults**.  Each vault is a separate
///      contract with its own `balanceOf` storage slot, so flash-access
///      transactions routed to *different* lanes touch disjoint ERC-20 state
///      and can execute concurrently on Monad without conflict.
///
///      Parallelism guarantee is **per-lane**: two callers assigned to the
///      *same* lane may still conflict / serialize, but callers on different
///      lanes never do.
///
///      Fee routing (pull pattern): collected fees accrue in each lane vault
///      and are NOT transferred to `feeReceiver` on every flash access.  A
///      permissionless `claimFees()` function sweeps accrued fees to the
///      receiver.  This avoids a DoS vector (a reverting / blacklisted
///      `feeReceiver` can never block flash access) and eliminates the
///      cross-lane serialization that a per-flash push transfer would cause.
///
///      Slashing: fee shortfalls trigger a **proportional** slash equal to
///      the shortfall amount (capped to the caller's bond), NOT the full
///      `minBond`.  This makes penalties rational and predictable.
contract ParallelPool is IParallelPool {
    using SafeERC20 for IERC20;

    // ── Immutables ──────────────────────────────────────────────────

    /// @notice The token held by this pool
    IERC20 public immutable override token;

    /// @notice The bond registry for access control
    IBondRegistry public immutable override bondRegistry;

    /// @notice Minimum bond required to use flash access
    uint256 public immutable override minBond;

    /// @notice Fee charged on flash access (basis points, e.g. 10 = 0.1%)
    uint256 public immutable feeBps;

    /// @notice Number of parallel lanes
    uint256 public immutable override numLanes;

    /// @notice Address that receives collected flash-access fees
    address public immutable override feeReceiver;

    // ── Lane state ──────────────────────────────────────────────────

    /// @notice Lane vault contracts (index = laneId)
    LaneVault[] internal _lanes;

    /// @notice Per-lane reentrancy guard.
    ///         Different lanes use independent locks so concurrent txs on
    ///         separate lanes never contend on the same storage slot.
    ///         0 = unlocked, 1 = locked.
    mapping(uint256 => uint256) private _laneLocked;

    /// @notice Global reentrancy guard for deposit/withdraw/claimFees.
    ///         Separate from per-lane locks to protect global state without
    ///         interfering with per-lane parallelism.
    ///         0 = unlocked, 1 = locked.
    uint256 private _globalLocked;

    /// @notice Flash-access activity counter.
    ///         Non-zero while any flash-access callback is executing.
    ///         Incremented/decremented (not set/cleared) so nested flash
    ///         accesses across different lanes keep the guard active until
    ///         the outermost callback returns.
    ///         Prevents deposit / withdraw / claimFees from being called
    ///         inside a callback, which would corrupt fee accounting
    ///         (deposit tokens landing in the active lane vault would be
    ///         mistakenly counted as fee payment).
    uint256 private _flashActive;

    /// @notice Unclaimed fees accrued per lane (pull pattern).
    ///         Fees stay in the lane vault until `claimFees()` is called.
    mapping(uint256 => uint256) public override accruedFees;

    // ── LP state (global) ───────────────────────────────────────────

    /// @notice Total liquidity deposited by LPs
    uint256 public totalDeposits;

    /// @notice Per-LP deposit balance
    mapping(address => uint256) public deposits;

    // ── Accountability ─────────────────────────────────────────────

    /// @notice Registered callbacks per protocol.
    ///         `callback == protocol` is always allowed.
    ///         Additional callbacks must be registered here first.
    mapping(address protocol => mapping(address callback => bool)) public registeredCallbacks;

    /// @notice Authorized executors per protocol.
    ///         For `flashAccessFor`, the executor (msg.sender) must be
    ///         authorized by the protocol, OR be the protocol itself.
    mapping(address protocol => mapping(address executor => bool)) public authorizedExecutors;

    // ── Errors ──────────────────────────────────────────────────────

    error InsufficientBond();
    error InsufficientLiquidity();
    error InvariantViolation();
    error ReentrancyGuard();
    error ExceedsDeposit();
    error InvalidNumLanes();
    error ZeroAddress();
    error FeeBpsTooHigh();
    error UnauthorizedCallback();
    error UnauthorizedExecutor();
    error FlashAccessActive();

    // ── Modifiers ───────────────────────────────────────────────────

    /// @dev Per-lane reentrancy guard.  Two flash-access txs on different
    ///      lanes never touch the same lock slot → no false conflicts.
    modifier laneNonReentrant(uint256 laneId) {
        if (_laneLocked[laneId] != 0) revert ReentrancyGuard();
        _laneLocked[laneId] = 1;
        _;
        _laneLocked[laneId] = 0;
    }

    /// @dev Global reentrancy guard for deposit / withdraw / claimFees.
    ///      These operations touch global state and are NOT parallel-safe,
    ///      so they share a single lock (separate from per-lane locks).
    modifier globalNonReentrant() {
        if (_globalLocked != 0) revert ReentrancyGuard();
        _globalLocked = 1;
        _;
        _globalLocked = 0;
    }

    /// @dev Blocks deposit / withdraw / claimFees while a flash-access
    ///      callback is executing.  Without this, a callback could call
    ///      `deposit()`, pushing tokens into the active lane vault that
    ///      `_settle()` would mis-classify as fee payment — permanently
    ///      extracting LP value into `accruedFees`.
    modifier noFlashActive() {
        if (_flashActive != 0) revert FlashAccessActive();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────

    /// @param _token        The ERC-20 token this pool holds
    /// @param _bondRegistry The BondRegistry contract
    /// @param _minBond      Minimum bond required for flash access
    /// @param _feeBps       Fee in basis points (e.g. 10 = 0.1%)
    /// @param _numLanes     Number of parallel lanes (e.g. 4–8)
    /// @param _feeReceiver  Address that receives collected fees
    constructor(
        address _token,
        address _bondRegistry,
        uint256 _minBond,
        uint256 _feeBps,
        uint256 _numLanes,
        address _feeReceiver
    ) {
        if (_token == address(0)) revert ZeroAddress();
        if (_bondRegistry == address(0)) revert ZeroAddress();
        if (_feeReceiver == address(0)) revert ZeroAddress();
        if (_numLanes == 0 || _numLanes > 32) revert InvalidNumLanes();
        if (_feeBps > 10000) revert FeeBpsTooHigh();

        token = IERC20(_token);
        bondRegistry = IBondRegistry(_bondRegistry);
        minBond = _minBond;
        feeBps = _feeBps;
        numLanes = _numLanes;
        feeReceiver = _feeReceiver;

        // Deploy one vault per lane
        for (uint256 i = 0; i < _numLanes; i++) {
            _lanes.push(new LaneVault(_token, address(this), i));
        }
    }

    // ── LP operations ───────────────────────────────────────────────
    // NOTE: deposit/withdraw touch ALL lane vaults and global accounting
    // (totalDeposits, deposits[sender]).  These operations are NOT parallel-
    // safe and will serialize with concurrent flash accesses.  The parallel
    // guarantee applies to flash access only.

    /// @inheritdoc IParallelPool
    /// @dev Uses balance-delta accounting so fee-on-transfer or rebasing tokens
    ///      cannot inflate `totalDeposits` beyond real liquidity.
    function deposit(uint256 amount) external globalNonReentrant noFlashActive {
        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - balBefore;

        deposits[msg.sender] += received;
        totalDeposits += received;

        // Distribute tokens evenly across lanes; remainder goes to lane 0.
        uint256 perLane = received / numLanes;
        uint256 remainder = received % numLanes;

        for (uint256 i = 0; i < numLanes; i++) {
            uint256 laneAmount = perLane + (i == 0 ? remainder : 0);
            if (laneAmount > 0) {
                token.safeTransfer(address(_lanes[i]), laneAmount);
            }
        }

        emit Deposit(msg.sender, received);
    }

    /// @inheritdoc IParallelPool
    function withdraw(uint256 amount) external globalNonReentrant noFlashActive {
        if (deposits[msg.sender] < amount) revert ExceedsDeposit();

        deposits[msg.sender] -= amount;
        totalDeposits -= amount;

        // Drain from lanes in order.  Under normal conditions each lane
        // holds roughly equal liquidity, so this completes quickly.
        // Lane balance is reduced by accrued fees (those belong to feeReceiver).
        uint256 remaining = amount;
        for (uint256 i = 0; i < numLanes && remaining > 0; i++) {
            uint256 laneBal = _laneLpBalance(i);
            uint256 pull = remaining < laneBal ? remaining : laneBal;
            if (pull > 0) {
                _lanes[i].transferOut(msg.sender, pull);
                remaining -= pull;
            }
        }

        if (remaining > 0) revert InsufficientLiquidity();

        emit Withdraw(msg.sender, amount);
    }

    // ── Flash Access ────────────────────────────────────────────────

    // ── Accountability: callback + executor registration ─────────────

    /// @notice Register a callback address that can act on behalf of msg.sender.
    ///         `callback == protocol` is always allowed without registration.
    /// @param callback The callback contract to authorize
    /// @param allowed  Whether to allow or revoke
    function registerCallback(address callback, bool allowed) external {
        registeredCallbacks[msg.sender][callback] = allowed;
        emit CallbackRegistered(msg.sender, callback, allowed);
    }

    /// @notice Authorize an executor to call `flashAccessFor` on behalf of msg.sender.
    /// @param executor The executor address to authorize
    /// @param allowed  Whether to allow or revoke
    function authorizeExecutor(address executor, bool allowed) external {
        authorizedExecutors[msg.sender][executor] = allowed;
        emit ExecutorAuthorized(msg.sender, executor, allowed);
    }

    /// @inheritdoc IParallelPool
    function flashAccess(uint256 amount, address callback, bytes calldata data) external {
        // Accountability: callback must be the caller itself or pre-registered.
        if (callback != msg.sender && !registeredCallbacks[msg.sender][callback]) {
            revert UnauthorizedCallback();
        }
        uint256 laneId = protocolLane(msg.sender);
        _flashAccessOnLane(msg.sender, laneId, amount, callback, data);
    }

    /// @inheritdoc IParallelPool
    function flashAccessFor(address protocol, uint256 amount, address callback, bytes calldata data)
        external
    {
        // Executor must be authorized by the protocol (or be the protocol).
        if (msg.sender != protocol && !authorizedExecutors[protocol][msg.sender]) {
            revert UnauthorizedExecutor();
        }
        // Callback must be the protocol itself or registered by the protocol.
        if (callback != protocol && !registeredCallbacks[protocol][callback]) {
            revert UnauthorizedCallback();
        }
        // Lane is determined by the protocol (the bonded identity), not the executor.
        uint256 laneId = protocolLane(protocol);
        _flashAccessOnLane(protocol, laneId, amount, callback, data);
    }

    /// @dev Internal: execute flash access on a specific lane.
    ///
    /// Post-callback accounting:
    ///   feePaid      = balanceAfter - balanceBefore   (what was actually paid)
    ///   feeShortfall = fee - feePaid                  (what was underpaid)
    ///
    /// If feeShortfall > 0 → slash proportionally (slash = feeShortfall, capped to bond)
    /// If feePaid > 0      → accrue fees in the lane vault (pull pattern)
    ///
    /// Note: if the callback overpays (returns more than amount + fee), the
    /// excess is treated as fee and accrued in the vault.  LP liquidity is
    /// tracked via `accruedFees` so overpayment never inflates LP balances.
    /// @param protocol The bonded entity whose bond backs this access.
    ///                 For `flashAccess`, this is `msg.sender`.
    ///                 For `flashAccessFor`, this is the specified protocol.
    function _flashAccessOnLane(
        address protocol,
        uint256 laneId,
        uint256 amount,
        address callback,
        bytes calldata data
    ) internal laneNonReentrant(laneId) {
        // 1. Check bond requirement (against the PROTOCOL, not the executor)
        if (!bondRegistry.isBonded(protocol, minBond)) {
            revert InsufficientBond();
        }

        // 2. Check lane liquidity (exclude accrued fees — those belong to feeReceiver)
        LaneVault vault = _lanes[laneId];
        uint256 balanceBefore = token.balanceOf(address(vault));
        uint256 availableBefore =
            balanceBefore > accruedFees[laneId] ? balanceBefore - accruedFees[laneId] : 0;
        if (availableBefore < amount) {
            revert InsufficientLiquidity();
        }

        // 3. Calculate expected fee.
        //    Rounds DOWN — for very small borrows (amount * feeBps < 10000)
        //    the fee is 0, effectively a free flash access.  This is accepted
        //    because the cost of executing the tx exceeds the dust amount.
        //    If feeBps == 0, the pool is explicitly configured as fee-free.
        uint256 fee = (amount * feeBps) / 10000;

        // 4. Lock bond for the duration (prevents unbond-during-callback exploit)
        bondRegistry.lockBond(protocol, minBond);

        // 5. Transfer tokens from lane vault to callback
        vault.transferOut(callback, amount);

        // 6. Execute callback (callback must repay to vault, not pool).
        //    Block deposit / withdraw / claimFees for the duration of the
        //    callback AND settlement to prevent vault-balance manipulation
        //    that would corrupt fee accounting.  The counter (not boolean)
        //    handles nested flash accesses on different lanes correctly.
        _flashActive += 1;
        IFlashAccessCallback(callback)
            .onFlashAccess(address(token), amount, fee, address(vault), data);

        // 7. Settle: invariant check, slash, unlock, fee routing.
        //    _flashActive remains > 0 through settlement so that any external
        //    call inside _settle (e.g. BondRegistry.slash → bondToken.safeTransfer)
        //    cannot re-enter deposit/withdraw/claimFees.
        _settle(protocol, laneId, vault, balanceBefore, fee, amount, callback);
        _flashActive -= 1;
    }

    /// @dev Post-callback settlement: check invariants, slash if underpaid,
    ///      unlock bond, and accrue fees.  Extracted to avoid stack-too-deep.
    function _settle(
        address protocol,
        uint256 laneId,
        LaneVault vault,
        uint256 balanceBefore,
        uint256 fee,
        uint256 amount,
        address callback
    ) private {
        uint256 balanceAfter = token.balanceOf(address(vault));

        // Principal not returned → revert (pool solvency protected).
        if (balanceAfter < balanceBefore) revert InvariantViolation();

        // Compute fee accounting
        uint256 feePaid = balanceAfter - balanceBefore;
        uint256 feeShortfall = fee > feePaid ? fee - feePaid : 0;

        // Fee shortfall → proportional slash (against PROTOCOL bond)
        if (feeShortfall > 0) {
            uint256 currentBond = bondRegistry.bondOf(protocol);
            uint256 actualSlash = feeShortfall > currentBond ? currentBond : feeShortfall;
            bondRegistry.slash(protocol, feeShortfall);
            emit Slashed(protocol, laneId, feeShortfall, actualSlash);
        }

        // Unlock bond (clamped in registry if slashed to zero)
        bondRegistry.unlockBond(protocol, minBond);

        // Accrue fees in the lane vault (pull pattern).
        // Fees stay in the vault until claimFees() is called.  This prevents
        // a reverting / blacklisted feeReceiver from blocking flash access.
        if (feePaid > 0) {
            accruedFees[laneId] += feePaid;
            emit FeesAccrued(laneId, feePaid);
        }

        emit FlashAccess(protocol, callback, laneId, amount, fee, feePaid);
    }

    // ── Fee claiming ─────────────────────────────────────────────────

    /// @inheritdoc IParallelPool
    /// @dev Permissionless.  If `feeReceiver` reverts (e.g. blacklisted),
    ///      fees remain accrued and flash access is unaffected.
    function claimFees() external globalNonReentrant noFlashActive {
        uint256 totalClaimed;
        for (uint256 i = 0; i < numLanes; i++) {
            uint256 fees = accruedFees[i];
            if (fees > 0) {
                accruedFees[i] = 0;
                _lanes[i].transferOut(feeReceiver, fees);
                totalClaimed += fees;
            }
        }
        if (totalClaimed > 0) {
            emit FeesClaimed(feeReceiver, totalClaimed);
        }
    }

    // ── Lane views ──────────────────────────────────────────────────

    /// @inheritdoc IParallelPool
    function protocolLane(address protocol) public view returns (uint256) {
        return uint256(uint160(protocol)) % numLanes;
    }

    /// @inheritdoc IParallelPool
    function laneVault(uint256 laneId) external view returns (address) {
        return address(_lanes[laneId]);
    }

    /// @inheritdoc IParallelPool
    /// @dev Returns LP liquidity only (vault balance minus unclaimed fees).
    ///
    ///      READ-ONLY REENTRANCY WARNING: During a flash-access callback, the
    ///      lane vault's token balance is temporarily reduced (tokens are with
    ///      the callback).  External protocols MUST NOT use this function as a
    ///      price oracle or collateral valuation during an active callback, as
    ///      the returned value will be transiently deflated.
    function laneLiquidity(uint256 laneId) external view returns (uint256) {
        return _laneLpBalance(laneId);
    }

    // ── Global views ────────────────────────────────────────────────

    /// @inheritdoc IParallelPool
    /// @dev Returns LP liquidity only (excludes unclaimed fees across all lanes).
    ///
    ///      READ-ONLY REENTRANCY WARNING: see `laneLiquidity` — the same caveat
    ///      applies.  During an active flash-access callback on any lane, the
    ///      total returned here will be transiently lower than the true value.
    function availableLiquidity() external view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < numLanes; i++) {
            total += _laneLpBalance(i);
        }
        return total;
    }

    /// @dev Returns LP-owned liquidity on a lane.
    ///      Saturates at zero if external token behavior (e.g. confiscation/rebase)
    ///      causes vault balance to drop below accrued fees.
    function _laneLpBalance(uint256 laneId) private view returns (uint256) {
        uint256 balance = token.balanceOf(address(_lanes[laneId]));
        uint256 fees = accruedFees[laneId];
        return balance > fees ? balance - fees : 0;
    }
}
