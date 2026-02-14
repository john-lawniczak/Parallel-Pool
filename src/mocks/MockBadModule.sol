// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "lib/forge-std/src/interfaces/IERC20.sol";
import { IParallelPool } from "../interfaces/IParallelPool.sol";
import { IFlashAccessCallback } from "../interfaces/IFlashAccessCallback.sol";

/// @title MockBadModule
/// @notice Demo module that returns principal but not fee (gets slashed)
contract MockBadModule is IFlashAccessCallback {
    IParallelPool public pool;

    constructor(address _pool) {
        pool = IParallelPool(_pool);
    }

    /// @notice Execute a flash access (demo: underpays fee)
    function execute(uint256 amount) external {
        pool.flashAccess(amount, address(this), "");
    }

    /// @inheritdoc IFlashAccessCallback
    function onFlashAccess(
        address token,
        uint256 amount,
        uint256,
        /* fee */
        address repayTo,
        bytes calldata /* data */
    )
        external
        override
    {
        // BAD: Return principal but not fee to the lane vault.
        // Pool remains solvent (no revert), but caller gets slashed.
        IERC20(token).transfer(repayTo, amount);
    }
}
