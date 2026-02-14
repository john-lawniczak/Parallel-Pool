// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { ParallelPool } from "../src/ParallelPool.sol";
import { BondRegistry } from "../src/BondRegistry.sol";
import { MockToken } from "../src/mocks/MockToken.sol";
import { MockSwapModule } from "../src/mocks/MockSwapModule.sol";
import { MockArbModule } from "../src/mocks/MockArbModule.sol";
import { MockBadModule } from "../src/mocks/MockBadModule.sol";

/// @notice Deploy + demo on Monad testnet.
///         Everything runs from the deployer wallet (single broadcast).
///         Deployer bonds itself, registers modules as callbacks, and
///         calls flashAccess directly — proving pull-based fee routing +
///         proportional slashing.
contract DemoScript is Script {
    uint256 constant MIN_BOND = 1000 ether;
    uint256 constant NUM_LANES = 4;

    function run() public {
        vm.startBroadcast();

        address deployer = msg.sender;
        console.log("Deployer:", deployer);

        // ── Deploy ──────────────────────────────────────────────
        MockToken poolToken = new MockToken("Pool Token", "POOL");
        MockToken paraToken = new MockToken("PRLL", "PRLL");
        BondRegistry registry = new BondRegistry(address(paraToken));

        ParallelPool pool = new ParallelPool(
            address(poolToken), address(registry), MIN_BOND, 10, NUM_LANES, deployer
        );
        registry.authorizePool(address(pool));

        MockSwapModule swapModule = new MockSwapModule(address(pool));
        MockArbModule arbModule = new MockArbModule(address(pool));
        MockBadModule badModule = new MockBadModule(address(pool));

        console.log("ParallelPool:", address(pool));
        console.log("BondRegistry:", address(registry));
        console.log("Lanes:", NUM_LANES);

        // ── Lane assignments ────────────────────────────────────
        _logLanes(pool, swapModule, arbModule, badModule);

        // ── Seed liquidity ──────────────────────────────────────
        poolToken.mint(deployer, 10_000 ether);
        poolToken.approve(address(pool), 10_000 ether);
        pool.deposit(10_000 ether);
        console.log("Deposited: 10,000 POOL");

        // ── Bond deployer ───────────────────────────────────────
        paraToken.mint(deployer, MIN_BOND);
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        console.log("Bonded:", MIN_BOND / 1e18, "PRLL");

        // ── Register modules as callbacks ───────────────────────
        pool.registerCallback(address(swapModule), true);
        pool.registerCallback(address(arbModule), true);
        pool.registerCallback(address(badModule), true);

        // ── Fund modules for fee repayment ──────────────────────
        poolToken.mint(address(swapModule), 100 ether);
        poolToken.mint(address(arbModule), 100 ether);

        // ── DEMO 1: Happy path (SwapModule) ────────────────────
        console.log("");
        console.log("--- DEMO 1: SwapModule (happy path) ---");
        pool.flashAccess(1000 ether, address(swapModule), "");
        console.log("Bond:", registry.bondOf(deployer) / 1e18, "PRLL");
        // Fees accrue in lane vault (pull pattern) — claim to receive
        uint256 receiverBefore1 = poolToken.balanceOf(deployer);
        pool.claimFees();
        console.log("Fees claimed:", poolToken.balanceOf(deployer) - receiverBefore1);

        // ── DEMO 2: Happy path (ArbModule) ─────────────────────
        console.log("");
        console.log("--- DEMO 2: ArbModule (happy path) ---");
        pool.flashAccess(500 ether, address(arbModule), "");
        console.log("Bond:", registry.bondOf(deployer) / 1e18, "PRLL");
        uint256 receiverBefore2 = poolToken.balanceOf(deployer);
        pool.claimFees();
        console.log("Fees claimed:", poolToken.balanceOf(deployer) - receiverBefore2);

        // ── DEMO 3: Fee shortfall → proportional slash ─────────
        console.log("");
        console.log("--- DEMO 3: BadModule (proportional slash) ---");
        uint256 bondPre = registry.bondOf(deployer);
        pool.flashAccess(500 ether, address(badModule), "");
        uint256 bondPost = registry.bondOf(deployer);
        console.log("Bond before:", bondPre);
        console.log("Bond after:", bondPost);
        console.log("Slashed:", bondPre - bondPost, "(proportional)");
        // BadModule pays principal but zero fee → no fees to claim
        pool.claimFees();

        // ── Final state ────────────────────────────────────────
        console.log("");
        console.log("--- FINAL STATE ---");
        for (uint256 i = 0; i < NUM_LANES; i++) {
            console.log("Lane", i, "liq:", pool.laneLiquidity(i));
            console.log("  accrued fees:", pool.accruedFees(i));
        }
        console.log("Total liq:", pool.availableLiquidity());
        console.log("Fee receiver total:", poolToken.balanceOf(deployer));
        console.log("DONE");

        vm.stopBroadcast();
    }

    function _logLanes(ParallelPool pool, MockSwapModule swap, MockArbModule arb, MockBadModule bad)
        internal
        view
    {
        console.log("SwapModule:", address(swap));
        console.log("  lane:", pool.protocolLane(address(swap)));
        console.log("ArbModule:", address(arb));
        console.log("  lane:", pool.protocolLane(address(arb)));
        console.log("BadModule:", address(bad));
        console.log("  lane:", pool.protocolLane(address(bad)));
    }
}
