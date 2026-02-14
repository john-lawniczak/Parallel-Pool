// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IBondRegistry } from "./IBondRegistry.sol";

/// @title IParallelPool
/// @notice Interface for the ParallelPool shared liquidity contract
interface IParallelPool {
    // ── Events ──────────────────────────────────────────────────────

    /// @notice Emitted on every completed flash access (success or slash).
    ///         Provides full audit trail for judges / indexers.
    event FlashAccess(
        address indexed caller,
        address indexed callback,
        uint256 indexed laneId,
        uint256 amount,
        uint256 fee,
        uint256 feePaid
    );

    /// @notice Emitted when a caller is slashed for fee shortfall.
    ///         Slash amount is proportional to the shortfall, NOT minBond.
    event Slashed(
        address indexed caller, uint256 indexed laneId, uint256 feeShortfall, uint256 slashAmount
    );

    /// @notice Emitted when fees accrue in a lane vault (pull pattern)
    event FeesAccrued(uint256 indexed laneId, uint256 amount);

    /// @notice Emitted when accrued fees are claimed and sent to the fee receiver
    event FeesClaimed(address indexed receiver, uint256 totalAmount);

    /// @notice Emitted when a protocol registers/revokes a callback
    event CallbackRegistered(address indexed protocol, address indexed callback, bool allowed);

    /// @notice Emitted when a protocol authorizes/revokes an executor
    event ExecutorAuthorized(address indexed protocol, address indexed executor, bool allowed);

    /// @notice Emitted when liquidity is deposited
    event Deposit(address indexed provider, uint256 amount);

    /// @notice Emitted when liquidity is withdrawn
    event Withdraw(address indexed provider, uint256 amount);

    // ── Flash Access ────────────────────────────────────────────────

    /// @notice Borrow tokens for the duration of the callback.
    ///         The caller is deterministically routed to a lane based on
    ///         `msg.sender`. Different lanes touch different vault contracts
    ///         so concurrent accesses on separate lanes never conflict.
    /// @param amount   Amount to borrow
    /// @param callback Contract that will receive the tokens and be called
    /// @param data     Arbitrary data to pass to callback
    /// @dev Caller must be bonded. Callback must be msg.sender or registered.
    ///      Reverts if principal not returned.
    ///      Slashes bond proportionally (without reverting) if fee not paid.
    function flashAccess(uint256 amount, address callback, bytes calldata data) external;

    /// @notice Delegated flash access: an authorized executor submits on
    ///         behalf of a bonded protocol.  Bond check, lock, and slash
    ///         all apply to `protocol`, not `msg.sender`.
    ///         Lane is determined by `protocol`.
    /// @param protocol The bonded protocol identity
    /// @param amount   Amount to borrow
    /// @param callback Contract that will receive the tokens and be called
    /// @param data     Arbitrary data to pass to callback
    /// @dev Executor must be authorized by protocol via `authorizeExecutor`.
    ///      Callback must be protocol itself or registered by protocol.
    function flashAccessFor(address protocol, uint256 amount, address callback, bytes calldata data)
        external;

    // ── Accountability ────────────────────────────────────────────────

    /// @notice Register (or revoke) a callback address for msg.sender.
    ///         `callback == protocol` is always allowed without registration.
    /// @param callback The callback contract to authorize
    /// @param allowed  Whether to allow or revoke
    function registerCallback(address callback, bool allowed) external;

    /// @notice Authorize (or revoke) an executor to call flashAccessFor on
    ///         behalf of msg.sender.
    /// @param executor The executor address
    /// @param allowed  Whether to allow or revoke
    function authorizeExecutor(address executor, bool allowed) external;

    // ── Fee claiming ─────────────────────────────────────────────────

    /// @notice Claim all accrued fees across every lane and send them to
    ///         the fee receiver.  Permissionless — anyone may trigger a claim.
    ///         If the fee receiver reverts, fees simply remain accrued; flash
    ///         access is never blocked.
    function claimFees() external;

    // ── LP operations ───────────────────────────────────────────────

    /// @notice Deposit liquidity (distributed evenly across all lanes)
    /// @param amount Amount to deposit
    function deposit(uint256 amount) external;

    /// @notice Withdraw liquidity (drained across lanes)
    /// @param amount Amount to withdraw
    function withdraw(uint256 amount) external;

    // ── Lane views ──────────────────────────────────────────────────

    /// @notice Number of parallel lanes
    function numLanes() external view returns (uint256);

    /// @notice Deterministic lane assignment for a protocol / caller
    /// @param protocol Address of the caller
    /// @return Lane id (0 .. numLanes-1)
    function protocolLane(address protocol) external view returns (uint256);

    /// @notice Address of the vault contract backing a lane
    /// @param laneId Lane identifier
    /// @return Vault address
    function laneVault(uint256 laneId) external view returns (address);

    /// @notice Current liquidity held in a specific lane vault
    /// @param laneId Lane identifier
    /// @return Token balance of the lane vault
    function laneLiquidity(uint256 laneId) external view returns (uint256);

    // ── Global views ────────────────────────────────────────────────

    /// @notice Total available liquidity across all lanes (excludes accrued fees)
    function availableLiquidity() external view returns (uint256);

    /// @notice Unclaimed fees accrued in a specific lane vault
    /// @param laneId Lane identifier
    /// @return Amount of unclaimed fees
    function accruedFees(uint256 laneId) external view returns (uint256);

    /// @notice The token held by this pool
    function token() external view returns (IERC20);

    /// @notice The bond registry used by this pool
    function bondRegistry() external view returns (IBondRegistry);

    /// @notice Minimum bond required to use flash access
    function minBond() external view returns (uint256);

    /// @notice Address that receives collected fees
    function feeReceiver() external view returns (address);
}
