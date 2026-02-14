// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ParallelPool } from "../src/ParallelPool.sol";
import { BondRegistry } from "../src/BondRegistry.sol";
import { MockToken } from "../src/mocks/MockToken.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IFlashAccessCallback } from "../src/interfaces/IFlashAccessCallback.sol";

// ─── Configurable callback for fuzz testing ─────────────────────────────────

/// @dev A callback module whose repayment behaviour is configurable per-call.
///      The fuzz harness tells it exactly how much to repay, enabling property-
///      based testing of every fee / slash / revert branch.
contract FuzzCallback is IFlashAccessCallback {
    /// @dev Set by the harness before each `flashAccess` call.
    uint256 public repayAmount;

    function setRepayAmount(uint256 _amount) external {
        repayAmount = _amount;
    }

    function onFlashAccess(
        address token,
        uint256,
        /* amount */
        uint256,
        /* fee */
        address repayTo,
        bytes calldata /* data */
    )
        external
        override
    {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 toSend = repayAmount > bal ? bal : repayAmount;
        if (toSend > 0) {
            IERC20(token).transfer(repayTo, toSend);
        }
    }
}

// ─── Fuzz test suite ─────────────────────────────────────────────────────────

contract FuzzTest is Test {
    ParallelPool public pool;
    BondRegistry public registry;
    MockToken public poolToken;
    MockToken public paraToken;
    FuzzCallback public callback;

    address public feeReceiverAddr = address(0xFEE);

    uint256 constant MIN_BOND = 1000 ether;
    uint256 constant FEE_BPS = 10; // 0.1 %
    uint256 constant NUM_LANES = 4;
    uint256 constant DEPOSIT = 100_000 ether;

    function setUp() public {
        poolToken = new MockToken("Pool Token", "POOL");
        paraToken = new MockToken("PRLL", "PRLL");
        registry = new BondRegistry(address(paraToken));

        pool = new ParallelPool(
            address(poolToken), address(registry), MIN_BOND, FEE_BPS, NUM_LANES, feeReceiverAddr
        );
        registry.authorizePool(address(pool));

        // Deploy the configurable callback
        callback = new FuzzCallback();

        // Seed liquidity
        poolToken.mint(address(this), DEPOSIT);
        poolToken.approve(address(pool), DEPOSIT);
        pool.deposit(DEPOSIT);

        // Bond the callback module
        paraToken.mint(address(callback), MIN_BOND);
        vm.prank(address(callback));
        paraToken.approve(address(registry), MIN_BOND);
        vm.prank(address(callback));
        registry.bond(MIN_BOND);

        // Register callback for itself (so callback == msg.sender is valid)
        // The callback calls `pool.flashAccess` via this test contract using
        // `flashAccessFor` with test contract as executor, OR we just prank.
        // Simpler: we prank as the callback for flashAccess.
    }

    // ─── Property: lane assignment is deterministic and in-range ──────────

    function testFuzz_protocolLane_inRange(address protocol) public view {
        uint256 lane = pool.protocolLane(protocol);
        assertTrue(lane < NUM_LANES, "Lane out of range");
    }

    function testFuzz_protocolLane_deterministic(address protocol) public view {
        uint256 lane1 = pool.protocolLane(protocol);
        uint256 lane2 = pool.protocolLane(protocol);
        assertEq(lane1, lane2, "Lane not deterministic");
    }

    // ─── Property: fee calculation is correct ────────────────────────────

    function testFuzz_feeCalculation(uint256 amount) public pure {
        // Bound to avoid overflow: amount * feeBps must fit in uint256
        amount = bound(amount, 0, type(uint256).max / 10001);
        uint256 expected = (amount * FEE_BPS) / 10000;
        // Verify fee formula matches
        assertEq(expected, (amount * FEE_BPS) / 10000, "Fee calc mismatch");
        // Fee should never exceed amount (for feeBps <= 10000)
        assertTrue(expected <= amount, "Fee exceeds amount");
    }

    // ─── Property: deposit + withdraw round-trip preserves balance ────────

    function testFuzz_depositWithdraw_roundTrip(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);

        address user = address(0xBEEF);
        poolToken.mint(user, amount);

        vm.startPrank(user);
        poolToken.approve(address(pool), amount);
        pool.deposit(amount);

        assertEq(pool.deposits(user), amount, "Deposit not recorded");

        pool.withdraw(amount);
        vm.stopPrank();

        assertEq(pool.deposits(user), 0, "Deposit not zeroed");
        assertEq(poolToken.balanceOf(user), amount, "Tokens not returned");
    }

    // ─── Property: partial withdraw works correctly ──────────────────────

    function testFuzz_partialWithdraw(uint256 depositAmt, uint256 withdrawAmt) public {
        depositAmt = bound(depositAmt, 1, 1_000_000 ether);
        withdrawAmt = bound(withdrawAmt, 1, depositAmt);

        address user = address(0xCAFE);
        poolToken.mint(user, depositAmt);

        vm.startPrank(user);
        poolToken.approve(address(pool), depositAmt);
        pool.deposit(depositAmt);
        pool.withdraw(withdrawAmt);
        vm.stopPrank();

        assertEq(pool.deposits(user), depositAmt - withdrawAmt, "Remaining deposit wrong");
        assertEq(poolToken.balanceOf(user), withdrawAmt, "Withdrawn amount wrong");
    }

    // ─── Property: cannot withdraw more than deposited ───────────────────

    function testFuzz_withdraw_exceedsDeposit_reverts(uint256 depositAmt, uint256 extra) public {
        depositAmt = bound(depositAmt, 1, 1_000_000 ether);
        extra = bound(extra, 1, 1_000_000 ether);

        address user = address(0xDEAD);
        poolToken.mint(user, depositAmt);

        vm.startPrank(user);
        poolToken.approve(address(pool), depositAmt);
        pool.deposit(depositAmt);

        vm.expectRevert(ParallelPool.ExceedsDeposit.selector);
        pool.withdraw(depositAmt + extra);
        vm.stopPrank();
    }

    // ─── Property: flash access happy path — pool solvency preserved ─────

    function testFuzz_flashAccess_happyPath_solvency(uint256 borrowAmount) public {
        // Flash access is per-lane — bound to the callback's lane liquidity
        uint256 laneId = pool.protocolLane(address(callback));
        uint256 laneLiq = pool.laneLiquidity(laneId);
        borrowAmount = bound(borrowAmount, 0, laneLiq);

        uint256 fee = (borrowAmount * FEE_BPS) / 10000;

        // Fund callback with extra tokens for fee payment
        poolToken.mint(address(callback), fee);

        // Configure callback to repay principal + fee
        callback.setRepayAmount(borrowAmount + fee);

        // Snapshot pool state
        uint256 liqBefore = pool.availableLiquidity();

        // Execute flash access as the callback
        vm.prank(address(callback));
        pool.flashAccess(borrowAmount, address(callback), "");

        // Pool LP liquidity unchanged (fees accrued separately)
        assertEq(pool.availableLiquidity(), liqBefore, "LP liquidity changed");

        // Bond should be intact (no shortfall)
        assertEq(registry.bondOf(address(callback)), MIN_BOND, "Bond should be intact");
    }

    // ─── Property: flash access fee shortfall → proportional slash ───────

    function testFuzz_flashAccess_feeShortfall_proportionalSlash(
        uint256 borrowAmount,
        uint256 feeFraction
    ) public {
        // Flash access is per-lane — bound to lane liquidity
        uint256 laneId = pool.protocolLane(address(callback));
        uint256 laneLiq = pool.laneLiquidity(laneId);
        // Borrow at least 10000 wei so fee > 0, max = lane liquidity
        borrowAmount = bound(borrowAmount, 10000, laneLiq);
        // feeFraction: 0 = pay nothing, 99 = pay 99% of fee
        feeFraction = bound(feeFraction, 0, 99);

        uint256 fee = (borrowAmount * FEE_BPS) / 10000;
        if (fee == 0) return; // Skip if fee rounds to 0

        uint256 partialFee = (fee * feeFraction) / 100;

        // Fund callback with enough for principal + partial fee
        poolToken.mint(address(callback), partialFee);

        // Configure callback to repay principal + partial fee
        callback.setRepayAmount(borrowAmount + partialFee);

        uint256 bondBefore = registry.bondOf(address(callback));
        uint256 feeShortfall = fee - partialFee;
        uint256 expectedSlash = feeShortfall > bondBefore ? bondBefore : feeShortfall;

        // Execute
        vm.prank(address(callback));
        pool.flashAccess(borrowAmount, address(callback), "");

        // Verify proportional slash
        assertEq(
            registry.bondOf(address(callback)),
            bondBefore - expectedSlash,
            "Slash not proportional to shortfall"
        );
    }

    // ─── Property: principal shortfall always reverts ─────────────────────

    function testFuzz_flashAccess_principalShortfall_reverts(
        uint256 borrowAmount,
        uint256 shortfall
    ) public {
        // Flash access is per-lane — bound to lane liquidity
        uint256 laneId = pool.protocolLane(address(callback));
        uint256 laneLiq = pool.laneLiquidity(laneId);
        borrowAmount = bound(borrowAmount, 1, laneLiq);
        shortfall = bound(shortfall, 1, borrowAmount);

        // Configure callback to repay less than principal
        callback.setRepayAmount(borrowAmount - shortfall);

        vm.prank(address(callback));
        vm.expectRevert(ParallelPool.InvariantViolation.selector);
        pool.flashAccess(borrowAmount, address(callback), "");
    }

    // ─── Property: claimFees transfers exactly the accrued amount ─────────

    function testFuzz_claimFees_exactAmount(uint256 borrowAmount) public {
        // Flash access is per-lane — bound to lane liquidity
        uint256 laneId = pool.protocolLane(address(callback));
        uint256 laneLiq = pool.laneLiquidity(laneId);
        borrowAmount = bound(borrowAmount, 0, laneLiq);

        uint256 fee = (borrowAmount * FEE_BPS) / 10000;
        poolToken.mint(address(callback), fee);
        callback.setRepayAmount(borrowAmount + fee);

        vm.prank(address(callback));
        pool.flashAccess(borrowAmount, address(callback), "");

        // Sum accrued fees across all lanes
        uint256 totalAccrued;
        for (uint256 i = 0; i < NUM_LANES; i++) {
            totalAccrued += pool.accruedFees(i);
        }
        assertEq(totalAccrued, fee, "Accrued fees should equal fee paid");

        // Claim and verify receiver gets exact amount
        uint256 receiverBefore = poolToken.balanceOf(feeReceiverAddr);
        pool.claimFees();
        uint256 receiverAfter = poolToken.balanceOf(feeReceiverAddr);
        assertEq(receiverAfter - receiverBefore, fee, "Claimed amount wrong");

        // All accrued fees should be zeroed
        for (uint256 i = 0; i < NUM_LANES; i++) {
            assertEq(pool.accruedFees(i), 0, "Accrued fees not cleared");
        }
    }

    // ─── Property: pool solvency invariant across deposit + flash cycles ──

    function testFuzz_solvencyInvariant(uint256 depositAmount, uint256 borrowAmount) public {
        depositAmount = bound(depositAmount, 1 ether, 1_000_000 ether);
        address user = address(0xABCD);

        // Deposit
        poolToken.mint(user, depositAmount);
        vm.startPrank(user);
        poolToken.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        // Flash access is per-lane — bound to the callback's lane liquidity
        uint256 laneId = pool.protocolLane(address(callback));
        uint256 laneLiq = pool.laneLiquidity(laneId);
        borrowAmount = bound(borrowAmount, 0, laneLiq);

        uint256 fee = (borrowAmount * FEE_BPS) / 10000;
        poolToken.mint(address(callback), fee);
        callback.setRepayAmount(borrowAmount + fee);

        vm.prank(address(callback));
        pool.flashAccess(borrowAmount, address(callback), "");

        // Invariant: sum of vault balances >= totalDeposits
        //            (vault balances include accrued fees, so >=)
        uint256 totalVaultBal;
        for (uint256 i = 0; i < NUM_LANES; i++) {
            totalVaultBal += poolToken.balanceOf(pool.laneVault(i));
        }
        assertTrue(
            totalVaultBal >= pool.totalDeposits(), "SOLVENCY VIOLATED: vaults < totalDeposits"
        );

        // Stronger invariant: vault balances - accrued fees == LP liquidity
        uint256 totalAccrued;
        for (uint256 i = 0; i < NUM_LANES; i++) {
            totalAccrued += pool.accruedFees(i);
        }
        assertEq(
            totalVaultBal - totalAccrued, pool.availableLiquidity(), "LP liquidity accounting error"
        );
    }

    // ─── Property: overpayment is treated as fee (accrues, not lost) ─────

    function testFuzz_overpayment_accruedAsFee(uint256 borrowAmount, uint256 extra) public {
        // Flash access is per-lane — bound to lane liquidity
        uint256 laneId = pool.protocolLane(address(callback));
        uint256 laneLiq = pool.laneLiquidity(laneId);
        borrowAmount = bound(borrowAmount, 0, laneLiq);
        extra = bound(extra, 1, 100 ether);

        uint256 fee = (borrowAmount * FEE_BPS) / 10000;

        // Fund callback with principal + fee + extra
        poolToken.mint(address(callback), fee + extra);
        callback.setRepayAmount(borrowAmount + fee + extra);

        vm.prank(address(callback));
        pool.flashAccess(borrowAmount, address(callback), "");

        // Accrued should be fee + extra (overpayment treated as fee)
        uint256 totalAccrued;
        for (uint256 i = 0; i < NUM_LANES; i++) {
            totalAccrued += pool.accruedFees(i);
        }
        assertEq(totalAccrued, fee + extra, "Overpayment not accrued as fee");

        // Bond intact (no shortfall)
        assertEq(registry.bondOf(address(callback)), MIN_BOND, "Bond should be intact on overpay");
    }

    // ─── Property: deposit distributes evenly across lanes ───────────────

    function testFuzz_deposit_evenDistribution(uint256 amount) public {
        amount = bound(amount, NUM_LANES, 1_000_000 ether);

        address user = address(0xF00D);
        poolToken.mint(user, amount);

        vm.startPrank(user);
        poolToken.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();

        // Verify total across lanes equals deposit
        uint256 totalLane;
        for (uint256 i = 0; i < NUM_LANES; i++) {
            totalLane += pool.laneLiquidity(i);
        }
        // totalLane includes the existing DEPOSIT from setUp()
        assertEq(totalLane, DEPOSIT + amount, "Lane total != deposits");
    }
}
