// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { ParallelPool } from "../src/ParallelPool.sol";
import { BondRegistry } from "../src/BondRegistry.sol";
import { Ownable } from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { Ownable2Step } from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import { MockToken } from "../src/mocks/MockToken.sol";
import { MockFeeToken } from "../src/mocks/MockFeeToken.sol";

// ═══════════════════════════════════════════════════════════════════════════
//  1. CONSTRUCTOR VALIDATION TESTS
// ═══════════════════════════════════════════════════════════════════════════

contract ConstructorValidationTest is Test {
    MockToken poolToken;
    MockToken paraToken;
    BondRegistry registry;

    function setUp() public {
        poolToken = new MockToken("Pool Token", "POOL");
        paraToken = new MockToken("PRLL", "PRLL");
        registry = new BondRegistry(address(paraToken));
    }

    // ── ParallelPool constructor ────────────────────────────────────

    address feeReceiver = address(0xFEE);

    function test_constructor_zeroToken_reverts() public {
        vm.expectRevert(ParallelPool.ZeroAddress.selector);
        new ParallelPool(address(0), address(registry), 1000 ether, 10, 4, feeReceiver);
    }

    function test_constructor_zeroBondRegistry_reverts() public {
        vm.expectRevert(ParallelPool.ZeroAddress.selector);
        new ParallelPool(address(poolToken), address(0), 1000 ether, 10, 4, feeReceiver);
    }

    function test_constructor_zeroFeeReceiver_reverts() public {
        vm.expectRevert(ParallelPool.ZeroAddress.selector);
        new ParallelPool(address(poolToken), address(registry), 1000 ether, 10, 4, address(0));
    }

    function test_constructor_zeroLanes_reverts() public {
        vm.expectRevert(ParallelPool.InvalidNumLanes.selector);
        new ParallelPool(address(poolToken), address(registry), 1000 ether, 10, 0, feeReceiver);
    }

    function test_constructor_tooManyLanes_reverts() public {
        vm.expectRevert(ParallelPool.InvalidNumLanes.selector);
        new ParallelPool(address(poolToken), address(registry), 1000 ether, 10, 33, feeReceiver);
    }

    function test_constructor_maxLanes_succeeds() public {
        ParallelPool pool = new ParallelPool(
            address(poolToken), address(registry), 1000 ether, 10, 32, feeReceiver
        );
        assertEq(pool.numLanes(), 32);
    }

    function test_constructor_feeBpsAtMax_succeeds() public {
        ParallelPool pool = new ParallelPool(
            address(poolToken), address(registry), 1000 ether, 10000, 4, feeReceiver
        );
        assertEq(pool.feeBps(), 10000);
    }

    function test_constructor_feeBpsAboveMax_reverts() public {
        vm.expectRevert(ParallelPool.FeeBpsTooHigh.selector);
        new ParallelPool(address(poolToken), address(registry), 1000 ether, 10001, 4, feeReceiver);
    }

    function test_constructor_zeroFeeBps_succeeds() public {
        ParallelPool pool = new ParallelPool(
            address(poolToken), address(registry), 1000 ether, 0, 4, feeReceiver
        );
        assertEq(pool.feeBps(), 0);
    }

    function test_constructor_zeroMinBond_succeeds() public {
        ParallelPool pool =
            new ParallelPool(address(poolToken), address(registry), 0, 10, 4, feeReceiver);
        assertEq(pool.minBond(), 0);
    }

    // ── BondRegistry constructor ────────────────────────────────────

    function test_registryConstructor_zeroBondToken_reverts() public {
        vm.expectRevert(BondRegistry.ZeroAddress.selector);
        new BondRegistry(address(0));
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  2. FEE-ON-TRANSFER TOKEN TESTS
// ═══════════════════════════════════════════════════════════════════════════

contract FeeOnTransferTest is Test {
    ParallelPool pool;
    BondRegistry registry;
    MockFeeToken feeToken;
    MockToken paraToken;

    address lp = address(0xAA);

    uint256 constant TOKEN_FEE_BPS = 500; // 5% transfer fee
    uint256 constant NUM_LANES = 4;

    function setUp() public {
        // Deploy a fee-on-transfer token as the pool token
        feeToken = new MockFeeToken("Fee Token", "FEE", TOKEN_FEE_BPS);
        paraToken = new MockToken("PRLL", "PRLL");
        registry = new BondRegistry(address(paraToken));

        pool = new ParallelPool(
            address(feeToken),
            address(registry),
            1000 ether,
            10, // 0.1% pool fee
            NUM_LANES,
            address(0xFEE)
        );
        registry.authorizePool(address(pool));
    }

    function test_deposit_feeToken_creditsActualReceived() public {
        uint256 depositAmount = 10_000 ether;
        feeToken.mint(lp, depositAmount);

        vm.startPrank(lp);
        feeToken.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        // 5% fee → pool receives 9_500.  Deposits should reflect actual received.
        uint256 expectedReceived = depositAmount - (depositAmount * TOKEN_FEE_BPS / 10000);
        assertEq(pool.deposits(lp), expectedReceived, "Deposit should credit actual received");
        assertEq(pool.totalDeposits(), expectedReceived, "totalDeposits should match actual");
    }

    function test_deposit_feeToken_laneLiquiditySumsCorrectly() public {
        uint256 depositAmount = 10_000 ether;
        feeToken.mint(lp, depositAmount);

        vm.startPrank(lp);
        feeToken.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);
        vm.stopPrank();

        // Sum of lane liquidity should equal totalDeposits (within the fee-on-transfer
        // context, the pool itself takes another 5% when distributing to lanes)
        uint256 totalInLanes = pool.availableLiquidity();

        // The deposit goes: LP → pool (loses 5%), then pool → lanes (loses another 5% each).
        // So lanes actually receive less than deposits[lp].  But deposits[lp] correctly
        // records what the pool received on the first transfer.
        // The key invariant: deposits[lp] reflects the actual first-hop received amount.
        uint256 expectedReceived = depositAmount - (depositAmount * TOKEN_FEE_BPS / 10000);
        assertEq(pool.deposits(lp), expectedReceived);

        // Lane liquidity will be less due to second fee on pool→lane transfers.
        // This is expected behavior with fee tokens — we document "standard ERC-20 only".
        assertTrue(
            totalInLanes < expectedReceived, "Fee token: lane liquidity < deposits (expected)"
        );
        assertTrue(totalInLanes > 0, "Lanes should have some liquidity");
    }

    function test_withdraw_feeToken_dropsCorrectAccounting() public {
        uint256 depositAmount = 10_000 ether;
        feeToken.mint(lp, depositAmount);

        vm.startPrank(lp);
        feeToken.approve(address(pool), depositAmount);
        pool.deposit(depositAmount);

        uint256 deposited = pool.deposits(lp);

        // Withdraw should fail if we try to withdraw more than lane liquidity
        // (since fee-on-transfer ate some on the pool→lane transfer)
        uint256 laneLiquidity = pool.availableLiquidity();
        assertTrue(laneLiquidity < deposited, "Precondition: lanes have less than deposited");

        // Withdraw only what's actually in the lanes
        pool.withdraw(laneLiquidity);
        vm.stopPrank();

        // LP's remaining deposit accounting
        assertEq(pool.deposits(lp), deposited - laneLiquidity);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  2b. BOND REGISTRY — FEE-ON-TRANSFER BOND TOKEN REGRESSION
// ═══════════════════════════════════════════════════════════════════════════

/// @dev Proves that BondRegistry.bond() credits ACTUAL received (balance-delta),
///      not the raw `amount` input, when the bond token takes a transfer fee.
///      Also ensures unbond() and slash() never rely on inflated accounting.
contract BondRegistryFeeTokenTest is Test {
    BondRegistry registry;
    MockFeeToken feeBondToken;
    MockToken poolToken;
    ParallelPool pool;

    address alice = address(0xAA);
    address poolAuth;

    uint256 constant FEE_BPS = 500; // 5% transfer fee
    uint256 constant BOND_AMOUNT = 1000 ether;

    function setUp() public {
        // Use a fee-on-transfer token as the BOND token
        feeBondToken = new MockFeeToken("Fee PRLL", "fPRLL", FEE_BPS);
        poolToken = new MockToken("Pool Token", "POOL");
        registry = new BondRegistry(address(feeBondToken));

        pool = new ParallelPool(
            address(poolToken), address(registry), 950 ether, 10, 4, address(0xFEE)
        );
        registry.authorizePool(address(pool));
        poolAuth = address(pool);

        // Mint fee bond tokens to alice
        feeBondToken.mint(alice, 10_000 ether);
    }

    /// @dev bondOf(user) must equal actual received, not the input amount.
    function test_bond_feeToken_creditsActualReceived() public {
        vm.startPrank(alice);
        feeBondToken.approve(address(registry), BOND_AMOUNT);
        registry.bond(BOND_AMOUNT);
        vm.stopPrank();

        // 5% fee → registry receives 950, not 1000
        uint256 expectedReceived = BOND_AMOUNT - (BOND_AMOUNT * FEE_BPS / 10000);
        assertEq(
            registry.bondOf(alice), expectedReceived, "bondOf should equal actual received amount"
        );
        // Registry's real token balance must match accounting
        assertEq(
            feeBondToken.balanceOf(address(registry)),
            expectedReceived,
            "Registry balance must match bonds accounting"
        );
    }

    /// @dev isBonded should reflect the actual (post-fee) bond, not inflated amount.
    function test_bond_feeToken_isBondedUsesActual() public {
        vm.startPrank(alice);
        feeBondToken.approve(address(registry), BOND_AMOUNT);
        registry.bond(BOND_AMOUNT);
        vm.stopPrank();

        uint256 expectedReceived = BOND_AMOUNT - (BOND_AMOUNT * FEE_BPS / 10000); // 950
        assertTrue(registry.isBonded(alice, expectedReceived), "Should be bonded for actual amount");
        assertFalse(
            registry.isBonded(alice, expectedReceived + 1),
            "Should NOT be bonded for more than actual"
        );
    }

    /// @dev unbond() should work correctly with the actual (deflated) bond balance.
    function test_unbond_feeToken_neverReliesOnInflated() public {
        vm.startPrank(alice);
        feeBondToken.approve(address(registry), BOND_AMOUNT);
        registry.bond(BOND_AMOUNT);

        uint256 actualBond = registry.bondOf(alice); // 950

        // Unbond the full actual bond — should succeed
        registry.unbond(actualBond);
        vm.stopPrank();

        assertEq(registry.bondOf(alice), 0, "Bond should be zero after full unbond");
    }

    /// @dev unbond(inputAmount) should revert because the actual bond is less than input.
    function test_unbond_feeToken_inputAmount_reverts() public {
        vm.startPrank(alice);
        feeBondToken.approve(address(registry), BOND_AMOUNT);
        registry.bond(BOND_AMOUNT);

        // Trying to unbond the original 1000 when only 950 was credited
        vm.expectRevert(BondRegistry.ExceedsBondBalance.selector);
        registry.unbond(BOND_AMOUNT);
        vm.stopPrank();
    }

    /// @dev slash() should work on the real bond, never over-slash.
    function test_slash_feeToken_cappedToActualBond() public {
        vm.startPrank(alice);
        feeBondToken.approve(address(registry), BOND_AMOUNT);
        registry.bond(BOND_AMOUNT);
        vm.stopPrank();

        uint256 actualBond = registry.bondOf(alice); // 950

        // Slash the full input amount (1000) — should cap to actual bond (950)
        vm.prank(poolAuth);
        registry.slash(alice, BOND_AMOUNT);

        assertEq(registry.bondOf(alice), 0, "Bond should be zero after full slash");
        // Slashed tokens sent to slashReceiver (BURN_ADDRESS)
        assertEq(
            feeBondToken.balanceOf(registry.slashReceiver()),
            actualBond - (actualBond * FEE_BPS / 10000),
            "slashReceiver should receive actual slashed (minus transfer fee)"
        );
    }

    /// @dev Multiple bonds accumulate correctly with fee-on-transfer.
    function test_bond_feeToken_multipleBondsAccumulate() public {
        vm.startPrank(alice);
        feeBondToken.approve(address(registry), BOND_AMOUNT * 3);

        registry.bond(BOND_AMOUNT);
        uint256 bond1 = registry.bondOf(alice);

        registry.bond(BOND_AMOUNT);
        uint256 bond2 = registry.bondOf(alice);

        vm.stopPrank();

        uint256 expectedPer = BOND_AMOUNT - (BOND_AMOUNT * FEE_BPS / 10000); // 950 each
        assertEq(bond1, expectedPer, "First bond should equal actual received");
        assertEq(bond2, expectedPer * 2, "Second bond should accumulate actual received");
        assertEq(
            feeBondToken.balanceOf(address(registry)), bond2, "Registry balance matches total bonds"
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  2c. FLASH-ACTIVE GUARD — DEPOSIT/WITHDRAW/CLAIMFEES BLOCKED IN CALLBACK
// ═══════════════════════════════════════════════════════════════════════════

/// @dev Malicious callback that tries to deposit into the pool during flash access.
///      Before the fix, this would inflate accruedFees and extract LP value.
contract DepositDuringCallbackModule is IFlashAccessCallback {
    ParallelPool public pool;
    MockToken public poolToken;

    bool public depositReverted;

    constructor(address _pool, address _poolToken) {
        pool = ParallelPool(_pool);
        poolToken = MockToken(_poolToken);
    }

    function execute(uint256 amount) external {
        pool.flashAccess(amount, address(this), "");
    }

    function onFlashAccess(
        address token,
        uint256 amount,
        uint256 fee,
        address repayTo,
        bytes calldata
    ) external override {
        // Attempt to deposit during callback — should revert with FlashAccessActive
        uint256 depositAmount = 1000 ether;
        poolToken.approve(address(pool), depositAmount);
        (bool ok,) =
            address(pool).call(abi.encodeWithSelector(ParallelPool.deposit.selector, depositAmount));
        depositReverted = !ok;

        // Repay principal + fee honestly
        MockToken(token).transfer(repayTo, amount + fee);
    }
}

/// @dev Callback that tries to withdraw during flash access.
contract WithdrawDuringCallbackModule is IFlashAccessCallback {
    ParallelPool public pool;

    bool public withdrawReverted;

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
        bytes calldata
    ) external override {
        // Attempt to withdraw during callback — should revert
        (bool ok,) =
            address(pool).call(abi.encodeWithSelector(ParallelPool.withdraw.selector, 1 ether));
        withdrawReverted = !ok;

        MockToken(token).transfer(repayTo, amount + fee);
    }
}

/// @dev Callback that tries to claimFees during flash access.
contract ClaimFeesDuringCallbackModule is IFlashAccessCallback {
    ParallelPool public pool;

    bool public claimReverted;

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
        bytes calldata
    ) external override {
        // Attempt to claimFees during callback — should revert
        (bool ok,) = address(pool).call(abi.encodeWithSelector(ParallelPool.claimFees.selector));
        claimReverted = !ok;

        MockToken(token).transfer(repayTo, amount + fee);
    }
}

import { IFlashAccessCallback } from "../src/interfaces/IFlashAccessCallback.sol";

/// @dev Proves deposit/withdraw/claimFees are blocked during flash-access
///      callbacks, preventing the phantom-fee inflation attack.
contract FlashActiveGuardTest is Test {
    ParallelPool pool;
    BondRegistry registry;
    MockToken poolToken;
    MockToken paraToken;

    DepositDuringCallbackModule depositAttacker;
    WithdrawDuringCallbackModule withdrawAttacker;
    ClaimFeesDuringCallbackModule claimAttacker;

    address lp = address(0xBB);

    uint256 constant MIN_BOND = 1000 ether;
    uint256 constant NUM_LANES = 4;
    uint256 constant FEE_BPS = 10;

    function setUp() public {
        poolToken = new MockToken("Pool Token", "POOL");
        paraToken = new MockToken("PRLL", "PRLL");
        registry = new BondRegistry(address(paraToken));

        pool = new ParallelPool(
            address(poolToken), address(registry), MIN_BOND, FEE_BPS, NUM_LANES, address(0xFEE)
        );
        registry.authorizePool(address(pool));

        // Seed LP liquidity
        poolToken.mint(lp, 10_000 ether);
        vm.startPrank(lp);
        poolToken.approve(address(pool), 10_000 ether);
        pool.deposit(10_000 ether);
        vm.stopPrank();

        // Deploy attacker modules
        depositAttacker = new DepositDuringCallbackModule(address(pool), address(poolToken));
        withdrawAttacker = new WithdrawDuringCallbackModule(address(pool));
        claimAttacker = new ClaimFeesDuringCallbackModule(address(pool));

        // Bond all attackers
        _bondModule(address(depositAttacker));
        _bondModule(address(withdrawAttacker));
        _bondModule(address(claimAttacker));

        // Fund deposit attacker with pool tokens for the deposit attempt
        poolToken.mint(address(depositAttacker), 2000 ether);

        // Fund all attackers with pool tokens for fee payment
        poolToken.mint(address(depositAttacker), 100 ether);
        poolToken.mint(address(withdrawAttacker), 100 ether);
        poolToken.mint(address(claimAttacker), 100 ether);

        // Give withdraw attacker a deposit so it could try to withdraw
        poolToken.mint(address(withdrawAttacker), 1000 ether);
        vm.startPrank(address(withdrawAttacker));
        poolToken.approve(address(pool), 1000 ether);
        pool.deposit(1000 ether);
        vm.stopPrank();
    }

    function _bondModule(address module) internal {
        paraToken.mint(module, MIN_BOND);
        vm.startPrank(module);
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();
    }

    /// @dev Deposit during callback must revert (FlashAccessActive).
    ///      Before the fix, this would succeed and inflate accruedFees.
    function test_depositDuringCallback_reverts() public {
        uint256 totalDepositsBefore = pool.totalDeposits();

        depositAttacker.execute(100 ether);

        // The deposit inside the callback should have reverted
        assertTrue(depositAttacker.depositReverted(), "Deposit during callback should revert");

        // totalDeposits should not have changed from the callback deposit
        assertEq(pool.totalDeposits(), totalDepositsBefore, "totalDeposits should be unchanged");

        // Bond should be intact (fee was paid honestly)
        assertEq(registry.bondOf(address(depositAttacker)), MIN_BOND, "Bond should be intact");
    }

    /// @dev Withdraw during callback must revert (FlashAccessActive).
    function test_withdrawDuringCallback_reverts() public {
        withdrawAttacker.execute(100 ether);

        assertTrue(withdrawAttacker.withdrawReverted(), "Withdraw during callback should revert");
    }

    /// @dev claimFees during callback must revert (FlashAccessActive).
    function test_claimFeesDuringCallback_reverts() public {
        claimAttacker.execute(100 ether);

        assertTrue(claimAttacker.claimReverted(), "claimFees during callback should revert");
    }

    /// @dev The full phantom-fee attack scenario: deposit during callback
    ///      would have allowed attacker to extract LP value. Now it's blocked.
    function test_phantomFeeAttack_fullScenario_blocked() public {
        uint256 lpDepositBefore = pool.deposits(lp);
        uint256 availBefore = pool.availableLiquidity();

        // Attacker executes flash access with deposit-during-callback
        depositAttacker.execute(100 ether);

        // LP's deposit and available liquidity should be preserved
        assertEq(pool.deposits(lp), lpDepositBefore, "LP deposit should be preserved");

        // Available liquidity should only change by the fee amount, not by phantom deposit
        uint256 expectedFee = (100 ether * FEE_BPS) / 10000; // 0.01 ether
        assertEq(
            pool.availableLiquidity(),
            availBefore,
            "Available liquidity should be unchanged (fee accrued separately)"
        );

        // The accrued fee should ONLY be the legitimate fee, not inflated by deposit
        uint256 totalAccrued;
        for (uint256 i = 0; i < NUM_LANES; i++) {
            totalAccrued += pool.accruedFees(i);
        }
        assertEq(totalAccrued, expectedFee, "Accrued fees should equal only the real fee");

        // LP can still withdraw their full deposit
        vm.prank(lp);
        pool.withdraw(lpDepositBefore);
        assertEq(pool.deposits(lp), 0, "LP should be able to withdraw everything");
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  3. ADMIN EVENTS + OWNERSHIP TRANSFER TESTS
// ═══════════════════════════════════════════════════════════════════════════

contract AdminEventsTest is Test {
    BondRegistry registry;
    MockToken paraToken;

    address deployer;
    address alice = address(0x1);
    address bob = address(0x2);
    address poolAddr = address(0x3);

    function setUp() public {
        deployer = address(this);
        paraToken = new MockToken("PRLL", "PRLL");
        registry = new BondRegistry(address(paraToken));
    }

    // ── Ownership transfer ──────────────────────────────────────────

    function test_transferOwnership_startsTwoStep() public {
        vm.expectEmit(true, true, false, true);
        emit Ownable2Step.OwnershipTransferStarted(deployer, alice);

        registry.transferOwnership(alice);
        assertEq(registry.pendingOwner(), alice);
        // Owner hasn't changed yet
        assertEq(registry.owner(), deployer);
    }

    function test_acceptOwnership_completes() public {
        registry.transferOwnership(alice);

        vm.expectEmit(true, true, false, true);
        emit Ownable.OwnershipTransferred(deployer, alice);

        vm.prank(alice);
        registry.acceptOwnership();

        assertEq(registry.owner(), alice);
        assertEq(registry.pendingOwner(), address(0));
    }

    function test_acceptOwnership_notPending_reverts() public {
        registry.transferOwnership(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        registry.acceptOwnership();
    }

    function test_transferOwnership_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.transferOwnership(bob);
    }

    function test_newOwner_canAuthorizePool() public {
        registry.transferOwnership(alice);
        vm.prank(alice);
        registry.acceptOwnership();

        // Old owner should fail
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer)
        );
        registry.authorizePool(poolAddr);

        // New owner should succeed
        vm.prank(alice);
        registry.authorizePool(poolAddr);
        assertTrue(registry.authorizedPools(poolAddr));
    }

    // ── setSlashReceiver event ──────────────────────────────────────

    function test_setSlashReceiver_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit BondRegistry.SlashReceiverUpdated(address(0xdead), alice);

        registry.setSlashReceiver(alice);
        assertEq(registry.slashReceiver(), alice);
    }

    function test_setSlashReceiver_zeroAddress_reverts() public {
        vm.expectRevert(BondRegistry.ZeroAddress.selector);
        registry.setSlashReceiver(address(0));
    }

    function test_setSlashReceiver_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setSlashReceiver(bob);
    }

    // ── authorizePool event ─────────────────────────────────────────

    function test_authorizePool_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit BondRegistry.PoolAuthorized(poolAddr);

        registry.authorizePool(poolAddr);
    }

    function test_authorizePool_zeroAddress_reverts() public {
        vm.expectRevert(BondRegistry.ZeroAddress.selector);
        registry.authorizePool(address(0));
    }

    // ── removePool event ────────────────────────────────────────────

    function test_removePool_emitsEvent() public {
        registry.authorizePool(poolAddr);

        vm.expectEmit(true, false, false, true);
        emit BondRegistry.PoolRemoved(poolAddr);

        registry.removePool(poolAddr);
        assertFalse(registry.authorizedPools(poolAddr));
    }
}
