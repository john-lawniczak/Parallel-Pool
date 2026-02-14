// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ParallelPool } from "../src/ParallelPool.sol";
import { BondRegistry } from "../src/BondRegistry.sol";
import { MockToken } from "../src/mocks/MockToken.sol";
import { IFlashAccessCallback } from "../src/interfaces/IFlashAccessCallback.sol";
import { ERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal authorized helper that can call unlockBond.
///      If BondRegistry has cross-pool lock attribution issues, this helper can
///      unlock someone else's active lock from another pool context.
contract MaliciousAuthorizedPoolHelper {
    BondRegistry public registry;

    constructor(address _registry) {
        registry = BondRegistry(_registry);
    }

    function unlockUser(address user, uint256 amount) external {
        registry.unlockBond(user, amount);
    }

    function slashUser(address user, uint256 amount) external {
        registry.slash(user, amount);
    }
}

/// @dev Callback that exploits cross-pool unlock + unbond during callback.
contract CrossPoolUnlockExploitModule is IFlashAccessCallback {
    ParallelPool public pool;
    BondRegistry public registry;
    MaliciousAuthorizedPoolHelper public helper;

    constructor(address _pool, address _registry, address _helper) {
        pool = ParallelPool(_pool);
        registry = BondRegistry(_registry);
        helper = MaliciousAuthorizedPoolHelper(_helper);
    }

    function execute(uint256 amount) external {
        pool.flashAccess(amount, address(this), "");
    }

    function onFlashAccess(
        address token,
        uint256 amount,
        uint256, /* fee */
        address repayTo,
        bytes calldata /* data */
    )
        external
        override
    {
        // 1) Illegitimately clear lock from another authorized "pool"
        uint256 locked = registry.lockedBondOf(address(this));
        helper.unlockUser(address(this), locked);

        // 2) Unbond everything while flash is still active
        uint256 bonded = registry.bondOf(address(this));
        if (bonded > 0) {
            // Keep callback alive even when unbond is correctly blocked.
            (bool ok,) =
                address(registry).call(abi.encodeWithSelector(BondRegistry.unbond.selector, bonded));
            ok;
        }

        // 3) Return principal only, underpay fee => should slash,
        //    but slash now has no collateral left to seize.
        MockToken(token).transfer(repayTo, amount);
    }
}

/// @dev Callback that triggers a cross-pool slash during an active lock and
///      then fully repays principal+fee. If unlock accounting is brittle,
///      pool unlock can revert due stale per-pool lock attribution.
contract CrossPoolSlashInterferenceModule is IFlashAccessCallback {
    ParallelPool public pool;
    BondRegistry public registry;
    MaliciousAuthorizedPoolHelper public helper;

    constructor(address _pool, address _registry, address _helper) {
        pool = ParallelPool(_pool);
        registry = BondRegistry(_registry);
        helper = MaliciousAuthorizedPoolHelper(_helper);
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
        // Slash from a different authorized pool while this pool's lock is active.
        helper.slashUser(address(this), type(uint256).max);
        // Fully repay principal+fee.
        MockToken(token).transfer(repayTo, amount + fee);
    }
}

/// @dev Token with arbitrary external burn for adversarial tests.
contract ShrinkableToken is ERC20 {
    constructor() ERC20("Shrinkable", "SHRK") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnFromAny(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract HonestFeeModule is IFlashAccessCallback {
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
        bytes calldata
    ) external override {
        MockToken(token).transfer(repayTo, amount + fee);
    }
}

contract SecurityFindingsTest is Test {
    ParallelPool public pool;
    BondRegistry public registry;
    MockToken public poolToken;
    MockToken public paraToken;
    MaliciousAuthorizedPoolHelper public helper;
    CrossPoolUnlockExploitModule public exploiter;
    CrossPoolSlashInterferenceModule public slashInterference;

    address public liquidityProvider = address(0x1234);
    address public feeReceiver = address(0xFEE);

    uint256 constant MIN_BOND = 1000 ether;
    uint256 constant FEE_BPS = 10; // 0.1%
    uint256 constant NUM_LANES = 4;

    function setUp() public {
        poolToken = new MockToken("Pool Token", "POOL");
        paraToken = new MockToken("PRLL", "PRLL");
        registry = new BondRegistry(address(paraToken));

        pool = new ParallelPool(
            address(poolToken), address(registry), MIN_BOND, FEE_BPS, NUM_LANES, feeReceiver
        );
        registry.authorizePool(address(pool));

        // Authorize malicious helper as an additional "pool"
        helper = new MaliciousAuthorizedPoolHelper(address(registry));
        registry.authorizePool(address(helper));

        exploiter =
            new CrossPoolUnlockExploitModule(address(pool), address(registry), address(helper));
        slashInterference =
            new CrossPoolSlashInterferenceModule(address(pool), address(registry), address(helper));

        // Seed pool liquidity
        poolToken.mint(liquidityProvider, 100_000 ether);
        vm.startPrank(liquidityProvider);
        poolToken.approve(address(pool), 100_000 ether);
        pool.deposit(10_000 ether);
        vm.stopPrank();

        // Give exploiter bond collateral + fee token balance for setup flexibility
        paraToken.mint(address(exploiter), 10_000 ether);
        poolToken.mint(address(exploiter), 1_000 ether);

        vm.startPrank(address(exploiter));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();

        paraToken.mint(address(slashInterference), 10_000 ether);
        poolToken.mint(address(slashInterference), 1_000 ether);
        vm.startPrank(address(slashInterference));
        paraToken.approve(address(registry), MIN_BOND);
        registry.bond(MIN_BOND);
        vm.stopPrank();
    }

    function test_crossPoolUnlock_cannotUnlockOtherPoolLock_regression() public {
        uint256 borrowAmount = 1000 ether;
        uint256 expectedFee = (borrowAmount * FEE_BPS) / 10000; // 1 ether

        uint256 slashReceiverBefore = paraToken.balanceOf(registry.slashReceiver());

        // Regression: helper cannot unlock a lock owned by a different pool.
        exploiter.execute(borrowAmount);

        // Unbond attempt is blocked; bond remains and is slashed for fee shortfall.
        assertEq(
            registry.bondOf(address(exploiter)),
            MIN_BOND - expectedFee,
            "Bond should remain locked then be slashed by fee shortfall"
        );
        assertEq(registry.lockedBondOf(address(exploiter)), 0, "No residual lock should remain");

        // Slash now lands correctly.
        assertEq(
            paraToken.balanceOf(registry.slashReceiver()),
            slashReceiverBefore + expectedFee,
            "Slash receiver should increase by expected fee shortfall"
        );

        // Receiver should still not receive flash fee (underpaid).
        pool.claimFees();
        assertEq(poolToken.balanceOf(feeReceiver), 0, "No fee should have been paid");
        assertEq(expectedFee, 1 ether, "Sanity check expected fee");
    }

    function test_crossPoolSlashDuringLock_doesNotBreakUnlock_regression() public {
        // This should complete without underflow/revert in unlockBond.
        slashInterference.execute(1000 ether);
        assertEq(registry.lockedBondOf(address(slashInterference)), 0, "Lock should clear cleanly");
    }
}

contract SecurityFindingsTokenBehaviorTest is Test {
    ParallelPool public pool;
    BondRegistry public registry;
    ShrinkableToken public token;
    MockToken public paraToken;
    HonestFeeModule public module;

    address public feeReceiver = address(0xFEE);

    uint256 constant MIN_BOND = 1000 ether;
    uint256 constant FEE_BPS = 10;
    uint256 constant NUM_LANES = 4;

    function setUp() public {
        token = new ShrinkableToken();
        paraToken = new MockToken("PRLL", "PRLL");
        registry = new BondRegistry(address(paraToken));
        pool = new ParallelPool(
            address(token), address(registry), MIN_BOND, FEE_BPS, NUM_LANES, feeReceiver
        );
        registry.authorizePool(address(pool));

        // Seed LP liquidity
        token.mint(address(this), 10_000 ether);
        token.approve(address(pool), 10_000 ether);
        pool.deposit(10_000 ether);

        // Setup honest module
        module = new HonestFeeModule(address(pool));
        paraToken.mint(address(module), 10_000 ether);
        vm.prank(address(module));
        paraToken.approve(address(registry), MIN_BOND);
        vm.prank(address(module));
        registry.bond(MIN_BOND);
        token.mint(address(module), 1_000 ether);
    }

    function test_externalBalanceShrink_viewsSaturateInsteadOfReverting_regression() public {
        // Accrue some fees first
        module.execute(1000 ether); // fee = 1 ether

        uint256 laneId = pool.protocolLane(address(module));
        address vault = pool.laneVault(laneId);
        uint256 accrued = pool.accruedFees(laneId);
        assertGt(accrued, 0, "Sanity: expected accrued fees");

        // Adversarial external shrink (rebase/confiscation-like behavior):
        // force vault balance below accruedFees so `balance - accruedFees` underflows.
        uint256 vaultBal = token.balanceOf(vault);
        uint256 targetBalance = accrued - 1;
        uint256 burnAmount = vaultBal - targetBalance;
        token.burnFromAny(vault, burnAmount);
        assertLt(
            token.balanceOf(vault), pool.accruedFees(laneId), "Sanity: expected balance < accrued"
        );

        // Regression: views should saturate at zero for the damaged lane, not revert.
        assertEq(pool.laneLiquidity(laneId), 0, "Damaged lane should saturate to 0 LP liquidity");
        pool.availableLiquidity();
    }
}
