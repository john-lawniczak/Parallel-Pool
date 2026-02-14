// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFlashAccessCallback
/// @notice Interface for contracts that want to use ParallelPool flash access
interface IFlashAccessCallback {
    /// @notice Called by ParallelPool during flashAccess
    /// @param token The token that was borrowed
    /// @param amount The amount of tokens borrowed
    /// @param fee The fee that must be paid (amount * feeBps / 10000)
    /// @param repayTo Address to send repayment to (the lane vault).
    ///        Callbacks MUST transfer (amount + fee) to this address, NOT msg.sender.
    ///        This enables parallel execution: each lane vault has its own balanceOf
    ///        slot, so concurrent accesses on different lanes never conflict.
    /// @param data Arbitrary data passed through from the caller
    function onFlashAccess(
        address token,
        uint256 amount,
        uint256 fee,
        address repayTo,
        bytes calldata data
    ) external;
}
