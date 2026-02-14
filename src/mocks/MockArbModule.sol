// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "lib/forge-std/src/interfaces/IERC20.sol";
import { IParallelPool } from "../interfaces/IParallelPool.sol";
import { IFlashAccessCallback } from "../interfaces/IFlashAccessCallback.sol";

/// @title MockArbModule
/// @notice Demo module that successfully uses flash access (happy path)
contract MockArbModule is IFlashAccessCallback {
    IParallelPool public pool;

    constructor(address _pool) {
        pool = IParallelPool(_pool);
    }

    /// @notice Execute a flash access (demo: always returns tokens + fee)
    function execute(uint256 amount) external {
        pool.flashAccess(amount, address(this), "");
    }

    /// @inheritdoc IFlashAccessCallback
    function onFlashAccess(
        address token,
        uint256 amount,
        uint256 fee,
        address repayTo,
        bytes calldata /* data */
    ) external override {
        // Simulate some arb logic here...
        // In a real module, this would do actual arbitrage

        // Return the borrowed amount + fee to the lane vault
        IERC20(token).transfer(repayTo, amount + fee);
    }

    /// @notice Allow this contract to receive tokens for fees
    function fundFees(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}
