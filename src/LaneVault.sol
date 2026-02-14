// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LaneVault
/// @notice Minimal token vault for a single ParallelPool lane.
/// @dev Each lane gets its own vault so `balanceOf[vault]` is a separate ERC-20
///      storage slot, enabling true parallel execution across lanes on Monad.
///      Two flash-access transactions routed to *different* lanes touch disjoint
///      state and can execute concurrently without conflict.
contract LaneVault {
    using SafeERC20 for IERC20;

    /// @notice The token held by this vault
    IERC20 public immutable token;

    /// @notice The ParallelPool that controls this vault
    address public immutable pool;

    /// @notice The lane this vault belongs to
    uint256 public immutable laneId;

    /// @notice Thrown when caller is not the pool
    error Unauthorized();

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    modifier onlyPool() {
        if (msg.sender != pool) revert Unauthorized();
        _;
    }

    /// @param _token  ERC-20 token this vault holds
    /// @param _pool   ParallelPool address (only caller allowed to move funds)
    /// @param _laneId Numeric lane identifier
    constructor(address _token, address _pool, uint256 _laneId) {
        if (_pool == address(0)) revert ZeroAddress();
        token = IERC20(_token);
        pool = _pool;
        laneId = _laneId;
    }

    /// @notice Transfer tokens out of this vault (pool only)
    /// @param to     Recipient address
    /// @param amount Amount to transfer
    function transferOut(address to, uint256 amount) external onlyPool {
        token.safeTransfer(to, amount);
    }

    /// @notice Current token balance held in this vault
    function liquidity() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
