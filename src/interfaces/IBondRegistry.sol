// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBondRegistry
/// @notice Interface for the bond registry that manages collateral
interface IBondRegistry {
    /// @notice Emitted when a user bonds tokens
    event Bonded(address indexed user, uint256 amount);

    /// @notice Emitted when a user unbonds tokens
    event Unbonded(address indexed user, uint256 amount);

    /// @notice Emitted when a user is slashed
    event Slashed(address indexed user, uint256 amount);

    /// @notice Emitted when a bond is locked by an authorized pool
    event BondLocked(address indexed user, uint256 amount);

    /// @notice Emitted when a bond is unlocked by an authorized pool
    event BondUnlocked(address indexed user, uint256 amount);

    /// @notice Post bond collateral
    /// @param amount Amount of $PRLL to bond
    function bond(uint256 amount) external;

    /// @notice Withdraw bond (if not actively using pool)
    /// @param amount Amount to withdraw
    function unbond(uint256 amount) external;

    /// @notice Lock a portion of a user's bond during flash access
    /// @param user User to lock
    /// @param amount Amount to lock
    /// @dev Only callable by authorized pool contracts
    function lockBond(address user, uint256 amount) external;

    /// @notice Unlock a portion of a user's bond after flash access
    /// @param user User to unlock
    /// @param amount Amount to unlock (clamped to current locked amount)
    /// @dev Only callable by authorized pool contracts
    function unlockBond(address user, uint256 amount) external;

    /// @notice Slash a user's bond (called by pool on invariant failure)
    /// @param user User to slash
    /// @param amount Amount to slash
    /// @dev Only callable by authorized pool contracts
    function slash(address user, uint256 amount) external;

    /// @notice Check if user has sufficient bond
    /// @param user User to check
    /// @param requiredAmount Minimum bond required
    /// @return True if user has sufficient bond
    function isBonded(address user, uint256 requiredAmount) external view returns (bool);

    /// @notice Get user's current bond balance
    /// @param user User to query
    /// @return Current bond balance
    function bondOf(address user) external view returns (uint256);

    /// @notice Get user's currently locked bond amount
    /// @param user User to query
    /// @return Locked bond amount
    function lockedBondOf(address user) external view returns (uint256);
}
