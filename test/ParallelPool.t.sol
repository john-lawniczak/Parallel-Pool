// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { ParallelPool } from "../src/ParallelPool.sol";
import { BondRegistry } from "../src/BondRegistry.sol";
import { LaneVault } from "../src/LaneVault.sol";
import { MockToken } from "../src/mocks/MockToken.sol";
import { MockSwapModule } from "../src/mocks/MockSwapModule.sol";
import { MockBadModule } from "../src/mocks/MockBadModule.sol";
import { IFlashAccessCallback } from "../src/interfaces/IFlashAccessCallback.sol";

// ─── Inline test modules ────────────────────────────────────────────────────

/// @dev Attempts the classic exploit: unbond during callback, then underpay fee.
contract MaliciousModule is IFlashAccessCallback {
    ParallelPool public pool;
    BondRegistry public registry;

    constructor(address _pool, address _registry) {
        pool = ParallelPool(_pool);
        registry = BondRegistry(_registry);
    }

    function execute(uint256 amount) external {
        pool.flashAccess(amount, address(this), "");
    }

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
        try registry.unbond(registry.bondOf(address(this))) { } catch { }
        // Return principal only (no fee) → triggers proportional slash.
        MockToken(token).transfer(repayTo, amount);
    }
}

/// @dev Returns less than principal, forcing the pool to revert.
contract PrincipalShortfallModule is IFlashAccessCallback {
    ParallelPool public pool;

    constructor(address _pool) {
        pool = ParallelPool(_pool);
    }

    function execute(uint256 amount) external {
        pool.flashAccess(amount, address(this), "");
    }

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
        MockToken(token).transfer(repayTo, amount - 1);
    }
}

/// @dev Attempts to unbond during callback but still repays principal+fee.
contract UnbondAttemptButPaysModule is IFlashAccessCallback {
    ParallelPool public pool;
    BondRegistry public registry;

    constructor(address _pool, address _registry) {
        pool = ParallelPool(_pool);
        registry = BondRegistry(_registry);
    }

    function execute(uint256 amount) external {
        pool.flashAccess(amount, address(this), "");
    }

    function onFlashAccess(
        address token,
        uint256 amount,
        uint256 fee,
        address repayTo,
        bytes calldata /* data */
    ) external override {
        try registry.unbond(registry.bondOf(address(this))) { } catch { }
        MockToken(token).transfer(repayTo, amount + fee);
    }
}

/// @dev Attempts reentrancy by calling flashAccess again inside callback.
contract ReentrantModule is IFlashAccessCallback {
    ParallelPool public pool;

    constructor(address _pool) {
        pool = ParallelPool(_pool);
    }

    function execute(uint256 amount) external {
        pool.flashAccess(amount, address(this), "");
    }

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
        pool.flashAccess(amount, address(this), "");
        MockToken(token).transfer(repayTo, amount);
    }
}

/// @dev Pays only half the fee — tests proportional slash.
contract HalfFeeModule is IFlashAccessCallback {
    ParallelPool public pool;

    constructor(address _pool) {
        pool = ParallelPool(_pool);
    }

    function execute(uint256 amount) external {
        pool.flashAccess(amount, address(this), "");
    }

    function onFlashAccess(
        address token,
        uint256 amount,
        uint256 fee,
        address repayTo,
        bytes calldata /* data */
    ) external override {
        // Pay principal + half the fee
        uint256 halfFee = fee / 2;
        MockToken(token).transfer(repayTo, amount + halfFee);
    }
}

// ─── Test contract ──────────────────────────────────────────────────────────

contract ParallelPoolTest is Test {
    ParallelPool public pool;
    BondRegistry public registry;
    MockToken public poolToken;
    MockToken public paraToken;
    MockSwapModule public swapModule;
    MockBadModule public badModule;

    address public alice = address(0x1);
    address public liquidityProvider = address(0x2);
    address public feeReceiverAddr = address(0xFEE);

    uint256 constant MIN_BOND = 1000 ether;
    uint256 constant FEE_BPS = 10; // 0.1%
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
        badModule = new MockBadModule(address(pool));

        // Setup liquidity
        poolToken.mint(liquidityProvider, 100_000 ether);
        vm.startPrank(liquidityProvider);
        poolToken.approve(address(pool), 100_000 ether);
        pool.deposit(10_000 ether);
        vm.stopPrank();

        // Setup modules with PRLL for bonding
        paraToken.mint(address(swapModule), 10_000 ether);
        paraToken.mint(address(badModule), 10_000 ether);

        // Fund swap module with tokens for fees
        poolToken.mint(address(swapModule), 1000 ether);
    }

    // ── Lane assignment tests ───────────────────────────────────────

    function test_numLanes() public view {
        assertEq(pool.numLanes(), NUM_LANES);
    }

    function test_feeReceiver() public view {
        assertEq(pool.feeReceiver(), feeReceiverAddr);
    }

    function test_protocolLane_deterministic() public view {
        uint256 lane1 = pool.protocolLane(address(swapModule));
        uint256 lane2 = pool.protocolLane(address(swapModule));
        assertEq(lane1, lane2, "Lane assignment not deterministic");
        assertTrue(lane1 < NUM_LANES, "Lane out of range");
    }

    function test_laneVault_returnsNonZeroAddress() public view {
        for (uint256 i = 0; i < NUM_LANES; i++) {
            assertTrue(pool.laneVault(i) != address(0), "Vault is zero address");
        }
    }

    function test_laneVaults_areDistinct() public view {
        for (uint256 i = 0; i < NUM_LANES; i++) {
            for (uint256 j = i + 1; j < NUM_LANES; j++) {
                assertTrue(pool.laneVault(i) != pool.laneVault(j), "Two lanes share vault");
            }
        }
    }

    function test_deposit_distributesAcrossLanes() public view {
        uint256 totalInLanes;
        for (uint256 i = 0; i < NUM_LANES; i++) {
            uint256 laneBal = pool.laneLiquidity(i);
            assertTrue(laneBal > 0, "Lane has zero liquidity");
            totalInLanes += laneBal;
        }
        assertEq(totalInLanes, 10_000 ether, "Total lane liquidity mismatch");
    }

    function test_laneLiquidity_sumsToAvailable() public view {
        uint256 total;
        for (uint256 i = 0; i < NUM_LANES; i++) {
            total += pool.laneLiquidity(i);
        }
        assertEq(total, pool.availableLiquidity());
    }

    // ── Flash access (happy path) ───────────────────────────────────

    function test_flashAccess_success_feesGoToReceiver() public {
        vm.startPrank(address(swapModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        uint256 borrowAmount = 1000 ether;
        uint256 expectedFee = (borrowAmount * FEE_BPS) / 10000; // 1 ether
        uint256 poolBalanceBefore = pool.availableLiquidity();
        uint256 receiverBefore = poolToken.balanceOf(feeReceiverAddr);

        swapModule.execute(borrowAmount);

        // Pool liquidity should be UNCHANGED (fees accrued, not extracted)
        assertEq(pool.availableLiquidity(), poolBalanceBefore, "Pool liq should not change");

        // Fees accrued but not yet claimed — receiver balance unchanged
        assertEq(poolToken.balanceOf(feeReceiverAddr), receiverBefore, "Fees not yet claimed");

        // Claim fees → receiver should now have the fee
        pool.claimFees();
        assertEq(
            poolToken.balanceOf(feeReceiverAddr),
            receiverBefore + expectedFee,
            "Fee receiver didn't get fee after claim"
        );

        // Bond should be intact
        assertEq(registry.bondOf(address(swapModule)), MIN_BOND);
    }

    function test_flashAccess_routesToCorrectLane_liquidityUnchanged() public {
        vm.startPrank(address(swapModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        uint256 laneId = pool.protocolLane(address(swapModule));
        uint256 laneBefore = pool.laneLiquidity(laneId);

        swapModule.execute(100 ether);

        // Lane liquidity unchanged because fee was extracted to receiver
        assertEq(pool.laneLiquidity(laneId), laneBefore, "Lane liq should be unchanged");
    }

    // ── Proportional slashing ───────────────────────────────────────

    function test_feeShortfall_slashesProportionally() public {
        // BadModule pays zero fee → shortfall = full fee amount
        vm.startPrank(address(badModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        uint256 borrowAmount = 1000 ether;
        uint256 expectedFee = (borrowAmount * FEE_BPS) / 10000; // 1 ether
        uint256 bondBefore = registry.bondOf(address(badModule));

        badModule.execute(borrowAmount);

        // Bond should be slashed by feeShortfall (1 ether), NOT minBond (1000 ether)
        assertEq(
            registry.bondOf(address(badModule)),
            bondBefore - expectedFee,
            "Slash should be proportional to fee shortfall"
        );
    }

    function test_halfFee_slashesHalfShortfall() public {
        HalfFeeModule halfFee = new HalfFeeModule(address(pool));

        paraToken.mint(address(halfFee), 10_000 ether);
        vm.startPrank(address(halfFee));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        // Fund with tokens so it can pay half the fee
        poolToken.mint(address(halfFee), 1000 ether);

        uint256 borrowAmount = 1000 ether;
        uint256 fee = (borrowAmount * FEE_BPS) / 10000; // 1 ether
        uint256 halfFeeAmount = fee / 2; // 0.5 ether
        uint256 expectedShortfall = fee - halfFeeAmount; // 0.5 ether

        uint256 bondBefore = registry.bondOf(address(halfFee));

        halfFee.execute(borrowAmount);

        // Slash = shortfall (0.5 ether)
        assertEq(
            registry.bondOf(address(halfFee)),
            bondBefore - expectedShortfall,
            "Slash should equal fee shortfall"
        );

        // Claim fees → fee receiver should get the partial fee that was paid
        pool.claimFees();
        assertEq(
            poolToken.balanceOf(feeReceiverAddr),
            halfFeeAmount,
            "Fee receiver should get partial fee after claim"
        );
    }

    function test_feeShortfall_slashedFundsGoToSlashReceiver() public {
        vm.startPrank(address(badModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        address slashReceiver = registry.slashReceiver();
        uint256 slashReceiverBefore = paraToken.balanceOf(slashReceiver);

        uint256 borrowAmount = 1000 ether;
        uint256 expectedFee = (borrowAmount * FEE_BPS) / 10000; // 1 ether = slash amount

        badModule.execute(borrowAmount);

        // Slashed PRLL should have been sent to slashReceiver (0xdead)
        assertEq(
            paraToken.balanceOf(slashReceiver),
            slashReceiverBefore + expectedFee,
            "Slashed funds not sent to slashReceiver"
        );
    }

    function test_feeShortfall_cappedToBond_whenBondLessThanShortfall() public {
        // Deploy a pool with minBond = 0.1 ether (very low) so the fee can exceed bond
        uint256 tinyBond = 0.1 ether;
        ParallelPool tinyPool = new ParallelPool(
            address(poolToken), address(registry), tinyBond, FEE_BPS, NUM_LANES, feeReceiverAddr
        );
        registry.authorizePool(address(tinyPool));

        // Create a bad module for this pool
        MockBadModule tinyBad = new MockBadModule(address(tinyPool));

        // Bond exactly tinyBond
        paraToken.mint(address(tinyBad), 10 ether);
        vm.startPrank(address(tinyBad));
        paraToken.approve(address(registry), tinyBond);
        registry.bond(tinyBond);
        vm.stopPrank();

        // Deposit liquidity into tinyPool
        poolToken.mint(address(this), 10_000 ether);
        poolToken.approve(address(tinyPool), 10_000 ether);
        tinyPool.deposit(10_000 ether);

        // Borrow 2000 ether → fee = 2 ether, but bond = 0.1 ether
        // feeShortfall (2 ether) > bond (0.1 ether) → slash capped to 0.1 ether
        uint256 borrowAmount = 2000 ether;
        uint256 fee = (borrowAmount * FEE_BPS) / 10000; // 2 ether
        assertTrue(fee > tinyBond, "Precondition: fee > bond");

        address slashReceiver = registry.slashReceiver();
        uint256 receiverBefore = paraToken.balanceOf(slashReceiver);

        tinyBad.execute(borrowAmount);

        // Bond should be fully slashed (capped to bond, not fee)
        assertEq(registry.bondOf(address(tinyBad)), 0, "Bond should be zero");

        // Slash receiver should get only the bond amount (0.1 ether), not the fee (2 ether)
        assertEq(
            paraToken.balanceOf(slashReceiver),
            receiverBefore + tinyBond,
            "Slash receiver should get capped amount, not full shortfall"
        );
    }

    // ── Flash access (failure cases) ────────────────────────────────

    function test_flashAccess_insufficientBond_reverts() public {
        vm.expectRevert(ParallelPool.InsufficientBond.selector);
        swapModule.execute(1000 ether);
    }

    function test_flashAccess_insufficientLiquidity_reverts() public {
        vm.startPrank(address(swapModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        vm.expectRevert(ParallelPool.InsufficientLiquidity.selector);
        swapModule.execute(100_000 ether);
    }

    // ── Exploit prevention ──────────────────────────────────────────

    function test_exploit_unbondDuringCallback_PREVENTED() public {
        MaliciousModule malicious = new MaliciousModule(address(pool), address(registry));

        paraToken.mint(address(malicious), 10_000 ether);
        vm.startPrank(address(malicious));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        uint256 borrowAmount = 1000 ether;
        uint256 expectedSlash = (borrowAmount * FEE_BPS) / 10000;
        uint256 bondBefore = registry.bondOf(address(malicious));

        malicious.execute(borrowAmount);

        // Unbond blocked → fee-underpayment → proportional slash
        assertEq(
            registry.bondOf(address(malicious)),
            bondBefore - expectedSlash,
            "Bond not slashed proportionally"
        );
    }

    function test_principalShortfall_reverts_andBondNotSlashed() public {
        PrincipalShortfallModule shortfall = new PrincipalShortfallModule(address(pool));

        paraToken.mint(address(shortfall), 10_000 ether);
        vm.startPrank(address(shortfall));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        uint256 bondBefore = registry.bondOf(address(shortfall));

        vm.expectRevert(ParallelPool.InvariantViolation.selector);
        shortfall.execute(1000 ether);

        assertEq(registry.bondOf(address(shortfall)), bondBefore, "Bond changed despite revert");
        assertEq(registry.lockedBondOf(address(shortfall)), 0, "Lock persisted despite revert");
    }

    function test_unbondAttemptDuringCallback_fails_butFlashSucceeds_andUnlocks() public {
        UnbondAttemptButPaysModule module =
            new UnbondAttemptButPaysModule(address(pool), address(registry));

        paraToken.mint(address(module), 10_000 ether);
        vm.startPrank(address(module));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        poolToken.mint(address(module), 1000 ether);

        module.execute(1000 ether);

        assertEq(registry.lockedBondOf(address(module)), 0, "Bond still locked after flash");

        vm.prank(address(module));
        registry.unbond(MIN_BOND);
        assertEq(registry.bondOf(address(module)), 0, "Unbond failed post-flash");
    }

    function test_reentrancy_blocked() public {
        ReentrantModule reentrant = new ReentrantModule(address(pool));

        paraToken.mint(address(reentrant), 10_000 ether);
        vm.startPrank(address(reentrant));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        vm.expectRevert(ParallelPool.ReentrancyGuard.selector);
        reentrant.execute(100 ether);
    }

    // ── Callback restriction ────────────────────────────────────────

    function test_flashAccess_callbackMustBeMsgSender_reverts() public {
        // Bond alice
        paraToken.mint(alice, MIN_BOND);
        vm.startPrank(alice);
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);

        // Alice tries to use swapModule as callback — not alice herself
        vm.expectRevert(ParallelPool.UnauthorizedCallback.selector);
        pool.flashAccess(100 ether, address(swapModule), "");
        vm.stopPrank();
    }

    function test_flashAccess_registeredCallback_succeeds() public {
        // Bond alice
        paraToken.mint(alice, MIN_BOND);
        vm.startPrank(alice);
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);

        // Register swapModule as callback for alice
        pool.registerCallback(address(swapModule), true);

        // Now alice can use swapModule as callback
        pool.flashAccess(100 ether, address(swapModule), "");
        vm.stopPrank();

        // Bond should be intact (swapModule paid fee)
        assertEq(registry.bondOf(alice), MIN_BOND, "Bond should be intact");
    }

    function test_flashAccess_revokedCallback_reverts() public {
        paraToken.mint(alice, MIN_BOND);
        vm.startPrank(alice);
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);

        // Register then revoke
        pool.registerCallback(address(swapModule), true);
        pool.registerCallback(address(swapModule), false);

        vm.expectRevert(ParallelPool.UnauthorizedCallback.selector);
        pool.flashAccess(100 ether, address(swapModule), "");
        vm.stopPrank();
    }

    function test_flashAccess_selfCallback_alwaysAllowed() public {
        // Standard pattern: module calls with callback == address(this)
        vm.startPrank(address(swapModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        // Module calls itself — no registration needed
        swapModule.execute(100 ether);
        assertEq(registry.bondOf(address(swapModule)), MIN_BOND, "Bond should be intact");
    }

    // ── Delegated execution (flashAccessFor) ──────────────────────

    function test_flashAccessFor_authorizedExecutor_succeeds() public {
        // Bond the swapModule (it will be the "protocol")
        vm.startPrank(address(swapModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);

        // Authorize alice as executor and register swapModule as its own callback
        pool.authorizeExecutor(alice, true);
        vm.stopPrank();

        uint256 bondBefore = registry.bondOf(address(swapModule));
        uint256 receiverBefore = poolToken.balanceOf(feeReceiverAddr);

        // Alice (executor) submits on behalf of swapModule (protocol)
        // callback = swapModule (which is the protocol, always allowed)
        vm.prank(alice);
        pool.flashAccessFor(address(swapModule), 100 ether, address(swapModule), "");

        // Bond on the PROTOCOL should be intact (fee was paid by swapModule)
        assertEq(registry.bondOf(address(swapModule)), bondBefore, "Protocol bond should be intact");
        // Claim fees then verify routed
        pool.claimFees();
        assertTrue(
            poolToken.balanceOf(feeReceiverAddr) > receiverBefore,
            "Fee should be routed after claim"
        );
    }

    function test_flashAccessFor_unauthorizedExecutor_reverts() public {
        vm.startPrank(address(swapModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        // Alice is NOT authorized — should revert
        vm.prank(alice);
        vm.expectRevert(ParallelPool.UnauthorizedExecutor.selector);
        pool.flashAccessFor(address(swapModule), 100 ether, address(swapModule), "");
    }

    function test_flashAccessFor_unauthorizedCallback_reverts() public {
        vm.startPrank(address(swapModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        pool.authorizeExecutor(alice, true);
        vm.stopPrank();

        // Alice is authorized executor, but badModule is NOT a registered callback for swapModule
        vm.prank(alice);
        vm.expectRevert(ParallelPool.UnauthorizedCallback.selector);
        pool.flashAccessFor(address(swapModule), 100 ether, address(badModule), "");
    }

    function test_flashAccessFor_protocolCanCallForSelf() public {
        // Protocol can call flashAccessFor on itself (no executor auth needed)
        vm.startPrank(address(swapModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        uint256 bondBefore = registry.bondOf(address(swapModule));

        // swapModule calls flashAccessFor on itself
        vm.prank(address(swapModule));
        pool.flashAccessFor(address(swapModule), 100 ether, address(swapModule), "");

        assertEq(registry.bondOf(address(swapModule)), bondBefore, "Bond intact");
    }

    function test_flashAccessFor_slashesProtocol_notExecutor() public {
        // Bond badModule (it's the protocol that will be slashed)
        vm.startPrank(address(badModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        pool.authorizeExecutor(alice, true);
        vm.stopPrank();

        uint256 protocolBondBefore = registry.bondOf(address(badModule));
        uint256 borrowAmount = 1000 ether;
        uint256 expectedSlash = (borrowAmount * FEE_BPS) / 10000;

        // Alice executes on behalf of badModule → fee not paid → protocol slashed
        vm.prank(alice);
        pool.flashAccessFor(address(badModule), borrowAmount, address(badModule), "");

        // PROTOCOL bond slashed, not alice's
        assertEq(
            registry.bondOf(address(badModule)),
            protocolBondBefore - expectedSlash,
            "Protocol bond should be slashed"
        );
    }

    function test_flashAccessFor_usesProtocolLane_notExecutorLane() public {
        vm.startPrank(address(swapModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        pool.authorizeExecutor(alice, true);
        vm.stopPrank();

        // Verify lane is based on protocol, not executor
        uint256 protocolLane = pool.protocolLane(address(swapModule));

        uint256 laneBefore = pool.laneLiquidity(protocolLane);

        vm.prank(alice);
        pool.flashAccessFor(address(swapModule), 100 ether, address(swapModule), "");

        // Protocol's lane should be the one used (liquidity unchanged since fee is routed)
        assertEq(pool.laneLiquidity(protocolLane), laneBefore, "Protocol lane should be used");
    }

    function test_authorizeExecutor_revokeBlocks() public {
        vm.startPrank(address(swapModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        pool.authorizeExecutor(alice, true);
        pool.authorizeExecutor(alice, false); // revoke
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(ParallelPool.UnauthorizedExecutor.selector);
        pool.flashAccessFor(address(swapModule), 100 ether, address(swapModule), "");
    }

    // ── Fee rounding edge cases ───────────────────────────────────

    function test_dustBorrow_feeRoundsToZero_noSlash() public {
        // Borrow 999 wei at 10 bps → fee = 999*10/10000 = 0
        // The callback returns exact principal → feePaid = 0, fee = 0 → no shortfall
        vm.startPrank(address(swapModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        uint256 bondBefore = registry.bondOf(address(swapModule));
        uint256 receiverBefore = poolToken.balanceOf(feeReceiverAddr);

        // 999 wei borrow: fee rounds to 0
        swapModule.execute(999);

        assertEq(
            registry.bondOf(address(swapModule)), bondBefore, "Bond should be intact (zero fee)"
        );
        // No fee → nothing routed
        assertEq(poolToken.balanceOf(feeReceiverAddr), receiverBefore, "No fee should be routed");
    }

    function test_zeroBorrow_noOp() public {
        vm.startPrank(address(swapModule));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        uint256 poolBefore = pool.availableLiquidity();
        uint256 bondBefore = registry.bondOf(address(swapModule));

        // Borrow 0 — valid but meaningless
        swapModule.execute(0);

        assertEq(pool.availableLiquidity(), poolBefore, "Pool unchanged");
        assertEq(registry.bondOf(address(swapModule)), bondBefore, "Bond unchanged");
    }

    function test_zeroFeeBps_noFeeCharged() public {
        // Deploy a pool with feeBps = 0
        ParallelPool freePool = new ParallelPool(
            address(poolToken),
            address(registry),
            MIN_BOND,
            0, // zero fee
            NUM_LANES,
            feeReceiverAddr
        );
        registry.authorizePool(address(freePool));

        MockSwapModule freeSwap = new MockSwapModule(address(freePool));

        // Deposit liquidity
        poolToken.mint(address(this), 10_000 ether);
        poolToken.approve(address(freePool), 10_000 ether);
        freePool.deposit(10_000 ether);

        // Bond module
        paraToken.mint(address(freeSwap), 10_000 ether);
        vm.startPrank(address(freeSwap));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        // Fund for fees (though none should be needed)
        poolToken.mint(address(freeSwap), 100 ether);

        uint256 receiverBefore = poolToken.balanceOf(feeReceiverAddr);

        freeSwap.execute(1000 ether);

        // No fee charged, nothing routed
        assertEq(poolToken.balanceOf(feeReceiverAddr), receiverBefore, "No fees with 0 bps");
        assertEq(registry.bondOf(address(freeSwap)), MIN_BOND, "Bond intact");
    }

    function test_maxFeeBps_feeEqualsAmount() public {
        // Deploy a pool with feeBps = 10000 (100%)
        ParallelPool maxPool = new ParallelPool(
            address(poolToken),
            address(registry),
            MIN_BOND,
            10000, // 100% fee
            NUM_LANES,
            feeReceiverAddr
        );
        registry.authorizePool(address(maxPool));

        MockSwapModule maxSwap = new MockSwapModule(address(maxPool));

        // Deposit liquidity
        poolToken.mint(address(this), 10_000 ether);
        poolToken.approve(address(maxPool), 10_000 ether);
        maxPool.deposit(10_000 ether);

        // Bond
        paraToken.mint(address(maxSwap), 10_000 ether);
        vm.startPrank(address(maxSwap));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        // Must fund callback with amount+fee = 2x amount
        poolToken.mint(address(maxSwap), 2000 ether);

        uint256 borrowAmount = 1000 ether;
        uint256 expectedFee = borrowAmount; // 100% fee
        uint256 receiverBefore = poolToken.balanceOf(feeReceiverAddr);

        maxSwap.execute(borrowAmount);

        // Claim fees then verify
        maxPool.claimFees();

        // Fee = 1000 ether = full borrow amount
        assertEq(
            poolToken.balanceOf(feeReceiverAddr),
            receiverBefore + expectedFee,
            "100% fee should equal borrow amount"
        );
        assertEq(registry.bondOf(address(maxSwap)), MIN_BOND, "Bond intact on full fee");
    }

    // ── LP deposit / withdraw ───────────────────────────────────────

    function test_deposit_withdraw() public {
        uint256 depositAmount = 5000 ether;

        poolToken.mint(alice, depositAmount);

        vm.startPrank(alice);
        poolToken.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        assertEq(pool.deposits(alice), depositAmount);

        vm.prank(alice);
        pool.withdraw(depositAmount);

        assertEq(pool.deposits(alice), 0);
        assertEq(poolToken.balanceOf(alice), depositAmount);
    }
}
