// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { BondRegistry } from "../src/BondRegistry.sol";
import { MockToken } from "../src/mocks/MockToken.sol";

contract BondRegistryTest is Test {
    BondRegistry public registry;
    MockToken public paraToken;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public pool = address(0x3);

    function setUp() public {
        paraToken = new MockToken("PRLL", "PRLL");
        registry = new BondRegistry(address(paraToken));

        // Authorize pool
        registry.authorizePool(pool);

        // Mint tokens to users
        paraToken.mint(alice, 10000 ether);
        paraToken.mint(bob, 10000 ether);
    }

    function test_bond_success() public {
        vm.startPrank(alice);
        paraToken.approve(address(registry), 1000 ether);
        registry.bond(1000 ether);
        vm.stopPrank();

        assertEq(registry.bondOf(alice), 1000 ether);
        assertTrue(registry.isBonded(alice, 1000 ether));
    }

    function test_unbond_success() public {
        vm.startPrank(alice);
        paraToken.approve(address(registry), 1000 ether);
        registry.bond(1000 ether);
        registry.unbond(500 ether);
        vm.stopPrank();

        assertEq(registry.bondOf(alice), 500 ether);
    }

    function test_unbond_lockedBond_reverts() public {
        vm.startPrank(alice);
        paraToken.approve(address(registry), 1000 ether);
        registry.bond(1000 ether);
        vm.stopPrank();

        // Pool locks the full bond.
        vm.prank(pool);
        registry.lockBond(alice, 1000 ether);

        vm.startPrank(alice);
        vm.expectRevert(BondRegistry.BondIsLocked.selector);
        registry.unbond(1 ether);
        vm.stopPrank();
    }

    function test_unbond_exceedsBalance_reverts() public {
        vm.startPrank(alice);
        paraToken.approve(address(registry), 1000 ether);
        registry.bond(1000 ether);

        vm.expectRevert(BondRegistry.ExceedsBondBalance.selector);
        registry.unbond(1001 ether);
        vm.stopPrank();
    }

    function test_slash_reducedBond() public {
        vm.startPrank(alice);
        paraToken.approve(address(registry), 1000 ether);
        registry.bond(1000 ether);
        vm.stopPrank();

        vm.prank(pool);
        registry.slash(alice, 500 ether);

        assertEq(registry.bondOf(alice), 500 ether);
    }

    function test_slash_unauthorizedPool_reverts() public {
        vm.startPrank(alice);
        paraToken.approve(address(registry), 1000 ether);
        registry.bond(1000 ether);
        vm.stopPrank();

        vm.prank(bob); // Not authorized
        vm.expectRevert(BondRegistry.Unauthorized.selector);
        registry.slash(alice, 500 ether);
    }

    function test_lockBond_overLocks_reverts() public {
        vm.startPrank(alice);
        paraToken.approve(address(registry), 1000 ether);
        registry.bond(1000 ether);
        vm.stopPrank();

        vm.prank(pool);
        registry.lockBond(alice, 1000 ether);

        vm.prank(pool);
        vm.expectRevert(BondRegistry.InsufficientBond.selector);
        registry.lockBond(alice, 1 ether);
    }

    function test_isBonded_true() public {
        vm.startPrank(alice);
        paraToken.approve(address(registry), 1000 ether);
        registry.bond(1000 ether);
        vm.stopPrank();

        assertTrue(registry.isBonded(alice, 500 ether));
        assertTrue(registry.isBonded(alice, 1000 ether));
    }

    function test_isBonded_false() public {
        vm.startPrank(alice);
        paraToken.approve(address(registry), 1000 ether);
        registry.bond(1000 ether);
        vm.stopPrank();

        assertFalse(registry.isBonded(alice, 1001 ether));
    }
}
