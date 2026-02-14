// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { ParallelPool } from "../src/ParallelPool.sol";
import { BondRegistry } from "../src/BondRegistry.sol";
import { MockToken } from "../src/mocks/MockToken.sol";
import { MockSwapModule } from "../src/mocks/MockSwapModule.sol";
import { MockArbModule } from "../src/mocks/MockArbModule.sol";
import { MockBadModule } from "../src/mocks/MockBadModule.sol";

contract DeployScript is Script {
    function run() public {
        vm.startBroadcast();

        // Deploy tokens
        MockToken poolToken = new MockToken("Pool Token", "POOL");
        MockToken paraToken = new MockToken("PRLL", "PRLL");

        console.log("Pool Token deployed:", address(poolToken));
        console.log("PRLL Token deployed:", address(paraToken));

        // Deploy registry
        BondRegistry registry = new BondRegistry(address(paraToken));
        console.log("BondRegistry deployed:", address(registry));
        console.log("  owner:", registry.owner());
        console.log("  slashReceiver (burn):", registry.slashReceiver());
        console.log("  BURN_ADDRESS:", registry.BURN_ADDRESS());

        // Deploy pool with 4 parallel lanes
        uint256 minBond = 1000 ether;
        uint256 feeBps = 10; // 0.1%
        uint256 numLanes = 4;

        address feeReceiver = msg.sender; // deployer as fee receiver for demo

        ParallelPool pool = new ParallelPool(
            address(poolToken), address(registry), minBond, feeBps, numLanes, feeReceiver
        );
        console.log("ParallelPool deployed:", address(pool));
        console.log("  numLanes:", numLanes);
        console.log("  feeReceiver:", feeReceiver);

        // Log lane vaults
        for (uint256 i = 0; i < numLanes; i++) {
            console.log("  Lane", i, "vault:", pool.laneVault(i));
        }

        // Authorize pool
        registry.authorizePool(address(pool));
        console.log("Pool authorized in registry");

        // Deploy demo modules
        MockSwapModule swapModule = new MockSwapModule(address(pool));
        MockArbModule arbModule = new MockArbModule(address(pool));
        MockBadModule badModule = new MockBadModule(address(pool));

        console.log(
            "SwapModule deployed:",
            address(swapModule),
            "-> lane",
            pool.protocolLane(address(swapModule))
        );
        console.log(
            "ArbModule deployed:",
            address(arbModule),
            "-> lane",
            pool.protocolLane(address(arbModule))
        );
        console.log(
            "BadModule deployed:",
            address(badModule),
            "-> lane",
            pool.protocolLane(address(badModule))
        );

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
    }
}
