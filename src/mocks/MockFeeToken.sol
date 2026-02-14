// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title MockFeeToken
/// @notice ERC-20 that takes a percentage fee on every transfer (fee-on-transfer token).
///         Used to test that ParallelPool correctly handles balance-delta accounting.
contract MockFeeToken is ERC20 {
    /// @notice Transfer fee in basis points (e.g. 500 = 5%)
    uint256 public feeBps;

    /// @notice Accumulated fees (burned / kept in contract)
    uint256 public feesCollected;

    constructor(string memory name, string memory symbol, uint256 _feeBps) ERC20(name, symbol) {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Override transfer to deduct fee.  Fee tokens are burned (not sent anywhere).
    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10000;
        uint256 net = amount - fee;
        if (fee > 0) {
            // Burn the fee portion
            _burn(msg.sender, fee);
            feesCollected += fee;
        }
        return super.transfer(to, net);
    }

    /// @dev Override transferFrom to deduct fee.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10000;
        uint256 net = amount - fee;
        if (fee > 0) {
            // Burn the fee from sender's balance (consuming allowance for full amount)
            _spendAllowance(from, msg.sender, amount);
            _burn(from, fee);
            feesCollected += fee;
            _transfer(from, to, net);
            return true;
        }
        return super.transferFrom(from, to, amount);
    }
}
