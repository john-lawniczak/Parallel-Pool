// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { Ownable2Step } from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import { IBondRegistry } from "./interfaces/IBondRegistry.sol";

/// @title BondRegistry
/// @notice Manages bond collateral for ParallelPool access.
/// @dev Protocols must bond $PRLL tokens to use flash access.
///      Ownership uses OpenZeppelin's Ownable2Step for safe two-step transfers.
///      `renounceOwnership` is disabled to prevent bricking admin functions.
contract BondRegistry is IBondRegistry, Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice The token used for bonding ($PRLL)
    IERC20 public immutable bondToken;

    /// @notice Bond balance per user
    mapping(address => uint256) public bonds;

    /// @notice Bond amounts locked during flash access (prevents unbond exploit)
    mapping(address => uint256) public lockedBonds;

    /// @notice Per-pool lock attribution: how much of a user's lock each pool owns.
    ///         This prevents one authorized pool from unlocking another pool's lock.
    mapping(address pool => mapping(address user => uint256)) public lockedByPool;

    /// @notice Authorized pools that can slash
    mapping(address => bool) public authorizedPools;

    /// @notice Canonical burn address — tokens sent here are irrecoverable.
    ///         Used as the default `slashReceiver`.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Receiver for slashed bond tokens (defaults to BURN_ADDRESS)
    address public slashReceiver = BURN_ADDRESS;

    // ── Admin events (ownership events inherited from OZ Ownable2Step) ──

    event SlashReceiverUpdated(address indexed previousReceiver, address indexed newReceiver);
    event PoolAuthorized(address indexed pool);
    event PoolRemoved(address indexed pool);

    // ── Errors ──────────────────────────────────────────────────────

    /// @notice Thrown when a non-authorized pool calls a pool-only function
    error Unauthorized();

    /// @notice Thrown when bond amount is insufficient
    error InsufficientBond();

    /// @notice Thrown when trying to unbond more than bonded
    error ExceedsBondBalance();

    /// @notice Thrown when trying to unbond locked bond
    error BondIsLocked();

    /// @notice Thrown when a zero address is provided where one is not allowed
    error ZeroAddress();

    /// @notice Thrown when renounceOwnership is called (permanently disabled)
    error RenounceDisabled();

    // ── Modifiers ───────────────────────────────────────────────────

    modifier onlyAuthorizedPool() {
        if (!authorizedPools[msg.sender]) revert Unauthorized();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────

    constructor(address _bondToken) Ownable(msg.sender) {
        if (_bondToken == address(0)) revert ZeroAddress();
        bondToken = IERC20(_bondToken);
    }

    // ── Ownership ───────────────────────────────────────────────────

    /// @dev Disabled — renouncing ownership would permanently brick all
    ///      admin functions (authorizePool, removePool, setSlashReceiver).
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ── Admin functions ─────────────────────────────────────────────

    /// @notice Set receiver for slashed tokens
    /// @dev Kept owner-controlled for MVP; document this power.
    function setSlashReceiver(address receiver) external onlyOwner {
        if (receiver == address(0)) revert ZeroAddress();
        emit SlashReceiverUpdated(slashReceiver, receiver);
        slashReceiver = receiver;
    }

    /// @notice Authorize a pool to slash bonds
    /// @param pool Pool address to authorize
    function authorizePool(address pool) external onlyOwner {
        if (pool == address(0)) revert ZeroAddress();
        authorizedPools[pool] = true;
        emit PoolAuthorized(pool);
    }

    /// @notice Remove pool authorization
    /// @param pool Pool address to remove
    function removePool(address pool) external onlyOwner {
        authorizedPools[pool] = false;
        emit PoolRemoved(pool);
    }

    // ── Bond operations ─────────────────────────────────────────────

    /// @inheritdoc IBondRegistry
    /// @dev Uses balance-delta accounting so fee-on-transfer or rebasing tokens
    ///      cannot inflate `bonds[user]` beyond the registry's real balance.
    function bond(uint256 amount) external {
        uint256 balBefore = bondToken.balanceOf(address(this));
        bondToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = bondToken.balanceOf(address(this)) - balBefore;

        bonds[msg.sender] += received;
        emit Bonded(msg.sender, received);
    }

    /// @inheritdoc IBondRegistry
    function unbond(uint256 amount) external {
        uint256 currentBond = bonds[msg.sender];
        if (currentBond < amount) revert ExceedsBondBalance();

        // Prevent unbonding of the portion locked by an authorized pool during flash access.
        uint256 locked = lockedBonds[msg.sender];
        uint256 available = currentBond > locked ? currentBond - locked : 0;
        if (amount > available) revert BondIsLocked();

        bonds[msg.sender] -= amount;
        bondToken.safeTransfer(msg.sender, amount);
        emit Unbonded(msg.sender, amount);
    }

    /// @inheritdoc IBondRegistry
    function lockBond(address user, uint256 amount) external onlyAuthorizedPool {
        uint256 currentBond = bonds[user];
        uint256 locked = lockedBonds[user];
        uint256 poolLocked = lockedByPool[msg.sender][user];

        // If another pool currently holds any lock for this user, block this lock.
        // This avoids cross-pool lock attribution ambiguity.
        if (locked > poolLocked) revert BondIsLocked();
        if (currentBond < locked || currentBond - locked < amount) revert InsufficientBond();

        lockedByPool[msg.sender][user] = poolLocked + amount;
        lockedBonds[user] = locked + amount;
        emit BondLocked(user, amount);
    }

    /// @inheritdoc IBondRegistry
    function unlockBond(address user, uint256 amount) external onlyAuthorizedPool {
        // A pool can only unlock the portion it previously locked.
        uint256 poolLocked = lockedByPool[msg.sender][user];
        uint256 toUnlock = amount > poolLocked ? poolLocked : amount;
        // Also clamp to the aggregate lock to guard against stale per-pool
        // lock attribution (e.g. if a different authorized pool slashed).
        uint256 locked = lockedBonds[user];
        if (toUnlock > locked) toUnlock = locked;
        if (toUnlock > 0) {
            lockedByPool[msg.sender][user] = poolLocked - toUnlock;
            lockedBonds[user] = locked - toUnlock;
            emit BondUnlocked(user, toUnlock);
        }
    }

    /// @inheritdoc IBondRegistry
    function slash(address user, uint256 amount) external onlyAuthorizedPool {
        uint256 currentBond = bonds[user];
        uint256 slashAmount = amount > currentBond ? currentBond : amount;

        if (slashAmount > 0) {
            bonds[user] -= slashAmount;

            // Keep aggregate/per-pool locks consistent after slashing.
            // Because cross-pool concurrent locks are disallowed in lockBond(),
            // any clamp here must apply to the caller's attributed lock.
            uint256 locked = lockedBonds[user];
            uint256 bondAfter = bonds[user];
            if (locked > bondAfter) {
                uint256 delta = locked - bondAfter;
                lockedBonds[user] = bondAfter;

                uint256 poolLocked = lockedByPool[msg.sender][user];
                lockedByPool[msg.sender][user] = delta > poolLocked ? 0 : poolLocked - delta;
            }

            // Send slashed tokens to receiver (defaults to BURN_ADDRESS).
            bondToken.safeTransfer(slashReceiver, slashAmount);
            emit Slashed(user, slashAmount);
        }
    }

    // ── Views ───────────────────────────────────────────────────────

    /// @inheritdoc IBondRegistry
    function isBonded(address user, uint256 requiredAmount) external view returns (bool) {
        return bonds[user] >= requiredAmount;
    }

    /// @inheritdoc IBondRegistry
    function bondOf(address user) external view returns (uint256) {
        return bonds[user];
    }

    /// @inheritdoc IBondRegistry
    function lockedBondOf(address user) external view returns (uint256) {
        return lockedBonds[user];
    }
}
