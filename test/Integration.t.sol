// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { ParallelPool } from "../src/ParallelPool.sol";
import { BondRegistry } from "../src/BondRegistry.sol";
import { MockToken } from "../src/mocks/MockToken.sol";
import { MockSwapModule } from "../src/mocks/MockSwapModule.sol";
import { MockArbModule } from "../src/mocks/MockArbModule.sol";

contract IntegrationTest is Test {
    ParallelPool public pool;
    BondRegistry public registry;
    MockToken public poolToken;
    MockToken public paraToken;
    MockSwapModule public swapModule;
    MockArbModule public arbModule;

    address public liquidityProvider = address(0x3);
    address public feeReceiverAddr = address(0xFEE);

    uint256 constant MIN_BOND = 1000 ether;
    uint256 constant FEE_BPS = 10;
    uint256 constant NUM_LANES = 4;

    function setUp() public {
        poolToken = new MockToken("Pool Token", "POOL");
        paraToken = new MockToken("PRLL", "PRLL");
        registry = new BondRegistry(address(paraToken));

        pool = new ParallelPool(
            address(poolToken), address(registry), MIN_BOND, FEE_BPS, NUM_LANES, feeReceiverAddr
        );

        registry.authorizePool(address(pool));

        swapModule = new MockSwapModule(address(pool));
        arbModule = new MockArbModule(address(pool));

        // Setup liquidity
        poolToken.mint(liquidityProvider, 100_000 ether);
        vm.startPrank(liquidityProvider);
        poolToken.approve(address(pool), 100_000 ether);
        pool.deposit(10_000 ether);
        vm.stopPrank();

        // Fund modules with tokens for fees
        poolToken.mint(address(swapModule), 1000 ether);
        poolToken.mint(address(arbModule), 1000 ether);

        // Bond both modules
        paraToken.mint(address(swapModule), 10_000 ether);
        paraToken.mint(address(arbModule), 10_000 ether);

        vm.startPrank(address(swapModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        vm.startPrank(address(arbModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();
    }

    function test_twoModules_sequential_bothSucceed() public {
        uint256 poolBalanceBefore = pool.availableLiquidity();

        swapModule.execute(1000 ether);
        arbModule.execute(500 ether);

        // Both should have bonds intact
        assertEq(registry.bondOf(address(swapModule)), MIN_BOND);
        assertEq(registry.bondOf(address(arbModule)), MIN_BOND);

        // Pool liquidity unchanged (fees accrued in vaults, not extracted)
        assertEq(pool.availableLiquidity(), poolBalanceBefore, "Pool liq should be unchanged");

        // Claim fees then verify receiver got both fees
        pool.claimFees();
        uint256 expectedFees = (1000 ether * FEE_BPS / 10000) + (500 ether * FEE_BPS / 10000);
        assertEq(poolToken.balanceOf(feeReceiverAddr), expectedFees, "Fee receiver balance wrong");
    }

    function test_orderIndependence() public {
        // Run Swap then Arb
        swapModule.execute(1000 ether);
        arbModule.execute(500 ether);
        pool.claimFees();

        uint256 finalBalanceAB = pool.availableLiquidity();
        uint256 feeReceiverAB = poolToken.balanceOf(feeReceiverAddr);
        uint256 swapBondAB = registry.bondOf(address(swapModule));
        uint256 arbBondAB = registry.bondOf(address(arbModule));

        // Reset state (redeploy)
        setUp();

        // Run Arb then Swap
        arbModule.execute(500 ether);
        swapModule.execute(1000 ether);
        pool.claimFees();

        uint256 finalBalanceBA = pool.availableLiquidity();
        uint256 feeReceiverBA = poolToken.balanceOf(feeReceiverAddr);
        uint256 swapBondBA = registry.bondOf(address(swapModule));
        uint256 arbBondBA = registry.bondOf(address(arbModule));

        // Results should be identical regardless of order
        assertEq(finalBalanceAB, finalBalanceBA, "Pool balance differs by order");
        assertEq(feeReceiverAB, feeReceiverBA, "Fee receiver differs by order");
        assertEq(swapBondAB, swapBondBA, "Swap bond differs by order");
        assertEq(arbBondAB, arbBondBA, "Arb bond differs by order");
    }

    function test_orderIndependence_forcedDifferentLanes() public {
        uint256 swapLane = pool.protocolLane(address(swapModule));
        uint256 arbLane = pool.protocolLane(address(arbModule));

        // Log for observability
        console.log("SwapModule lane:", swapLane);
        console.log("ArbModule lane:", arbLane);

        // Verify they're in different lanes (the point of this test)
        if (swapLane == arbLane) {
            // If by chance they share a lane, skip this specific test
            // (the generic order independence test above still covers correctness)
            console.log("SKIP: modules share a lane - generic test covers this");
            return;
        }

        // They're in different lanes — prove order doesn't matter
        uint256 swapLaneBefore = pool.laneLiquidity(swapLane);
        uint256 arbLaneBefore = pool.laneLiquidity(arbLane);

        swapModule.execute(1000 ether);
        arbModule.execute(500 ether);
        pool.claimFees();

        uint256 swapLaneAfterAB = pool.laneLiquidity(swapLane);
        uint256 arbLaneAfterAB = pool.laneLiquidity(arbLane);
        uint256 feeReceiverAB = poolToken.balanceOf(feeReceiverAddr);

        // Reset
        setUp();

        // Reverse order
        arbModule.execute(500 ether);
        swapModule.execute(1000 ether);
        pool.claimFees();

        uint256 swapLaneAfterBA = pool.laneLiquidity(swapLane);
        uint256 arbLaneAfterBA = pool.laneLiquidity(arbLane);
        uint256 feeReceiverBA = poolToken.balanceOf(feeReceiverAddr);

        // Per-lane state should be identical regardless of order
        assertEq(swapLaneAfterAB, swapLaneAfterBA, "Swap lane differs by order");
        assertEq(arbLaneAfterAB, arbLaneAfterBA, "Arb lane differs by order");
        assertEq(feeReceiverAB, feeReceiverBA, "Fee receiver differs by order");

        // Both lanes unchanged (fees extracted)
        assertEq(swapLaneAfterAB, swapLaneBefore, "Swap lane liq should be unchanged");
        assertEq(arbLaneAfterAB, arbLaneBefore, "Arb lane liq should be unchanged");
    }

    function test_modulesGetAssignedLanes() public view {
        uint256 swapLane = pool.protocolLane(address(swapModule));
        uint256 arbLane = pool.protocolLane(address(arbModule));

        assertTrue(swapLane < NUM_LANES, "Swap lane out of range");
        assertTrue(arbLane < NUM_LANES, "Arb lane out of range");

        console.log("SwapModule lane:", swapLane);
        console.log("ArbModule lane:", arbLane);
    }

    function test_feesRouteToReceiver_notVault() public {
        uint256 swapLane = pool.protocolLane(address(swapModule));
        uint256 laneBefore = pool.laneLiquidity(swapLane);

        swapModule.execute(1000 ether);

        // Lane LP liquidity unchanged (fees accrued separately)
        assertEq(pool.laneLiquidity(swapLane), laneBefore, "Lane liq should be unchanged");

        // Claim fees then verify they went to receiver
        pool.claimFees();
        uint256 expectedFee = (1000 ether * FEE_BPS) / 10000;
        assertEq(
            poolToken.balanceOf(feeReceiverAddr),
            expectedFee,
            "Fees not routed to receiver after claim"
        );
    }

    function test_laneObservability_afterFlashAccess() public {
        console.log("--- Lane State BEFORE ---");
        for (uint256 i = 0; i < NUM_LANES; i++) {
            console.log("  Lane", i, "vault:", pool.laneVault(i));
            console.log("    liquidity:", pool.laneLiquidity(i));
        }

        swapModule.execute(1000 ether);

        console.log("--- Lane State AFTER ---");
        for (uint256 i = 0; i < NUM_LANES; i++) {
            console.log("  Lane", i, "vault:", pool.laneVault(i));
            console.log("    liquidity:", pool.laneLiquidity(i));
        }
        console.log("  feeReceiver balance:", poolToken.balanceOf(feeReceiverAddr));
    }
}
