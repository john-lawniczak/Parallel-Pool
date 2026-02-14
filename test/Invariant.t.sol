// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ParallelPool } from "../src/ParallelPool.sol";
import { BondRegistry } from "../src/BondRegistry.sol";
import { MockToken } from "../src/mocks/MockToken.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IFlashAccessCallback } from "../src/interfaces/IFlashAccessCallback.sol";

// ─── Configurable callback for invariant handler ────────────────────────────

/// @dev Callback whose repayment is configured by the handler before each call.
contract InvariantCallback is IFlashAccessCallback {
    uint256 public repayAmount;

    function setRepayAmount(uint256 _amount) external {
        repayAmount = _amount;
    }

    function onFlashAccess(
        address token,
        uint256, /* amount */
        uint256, /* fee */
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

// ─── Handler: bounded actions the fuzzer can call ───────────────────────────

/// @dev The invariant fuzzer calls random functions on this contract.
///      Each function wraps a real protocol action with bounded inputs.
///      Ghost variables track cumulative state for invariant assertions.
contract PoolHandler is Test {
    ParallelPool public pool;
    BondRegistry public registry;
    MockToken public poolToken;
    MockToken public paraToken;
    InvariantCallback[3] public protocols;

    uint256 public constant NUM_LANES = 4;
    uint256 public constant MIN_BOND = 1000 ether;
    uint256 public constant FEE_BPS = 10;

    // ── Ghost variables: aggregate counters for invariant checks ──────────
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalFeesAccrued;
    uint256 public ghost_totalFeesClaimed;
    uint256 public ghost_totalActualSlashed;
    uint256 public ghost_flashAccessCount;
    uint256 public ghost_slashCount;
    uint256 public ghost_revertCount;

    // LP actors (rotated by the fuzzer via seed)
    address[3] public lps;
    address[2] public executors;

    constructor(
        ParallelPool _pool,
        BondRegistry _registry,
        MockToken _poolToken,
        MockToken _paraToken,
        InvariantCallback p0,
        InvariantCallback p1,
        InvariantCallback p2
    ) {
        pool = _pool;
        registry = _registry;
        poolToken = _poolToken;
        paraToken = _paraToken;
        protocols[0] = p0;
        protocols[1] = p1;
        protocols[2] = p2;

        lps[0] = address(uint160(0xA001));
        lps[1] = address(uint160(0xA002));
        lps[2] = address(uint160(0xA003));

        executors[0] = address(uint160(0xE001));
        executors[1] = address(uint160(0xE002));
    }

    // ── Action: deposit ──────────────────────────────────────────────────

    function handler_deposit(uint256 actorSeed, uint256 amount) external {
        address lp = lps[actorSeed % lps.length];
        amount = bound(amount, 1, 100_000 ether);

        poolToken.mint(lp, amount);
        vm.startPrank(lp);
        poolToken.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();

        ghost_totalDeposited += amount;
    }

    // ── Action: withdraw ─────────────────────────────────────────────────

    function handler_withdraw(uint256 actorSeed, uint256 amount) external {
        address lp = lps[actorSeed % lps.length];
        uint256 deposited = pool.deposits(lp);
        if (deposited == 0) return; // Nothing to withdraw

        amount = bound(amount, 1, deposited);

        vm.prank(lp);
        pool.withdraw(amount);

        ghost_totalWithdrawn += amount;
    }

    // ── Action: flash access (happy path — full fee) ─────────────────────

    function handler_flashAccess_happy(uint256 protocolSeed, uint256 amount) external {
        InvariantCallback protocol = _protocol(protocolSeed);
        uint256 laneId = pool.protocolLane(address(protocol));
        uint256 laneLiq = pool.laneLiquidity(laneId);
        if (laneLiq == 0) return; // No liquidity

        amount = bound(amount, 0, laneLiq);
        uint256 fee = (amount * FEE_BPS) / 10000;

        // Ensure callback has enough bond
        _ensureBonded(protocol);

        // Fund callback for fee
        poolToken.mint(address(protocol), fee);
        protocol.setRepayAmount(amount + fee);

        vm.prank(address(protocol));
        pool.flashAccess(amount, address(protocol), "");

        ghost_flashAccessCount++;
        ghost_totalFeesAccrued += fee;
    }

    // ── Action: flash access (partial fee → slash) ───────────────────────

    function handler_flashAccess_partialFee(uint256 protocolSeed, uint256 amount, uint256 feePct)
        external
    {
        InvariantCallback protocol = _protocol(protocolSeed);
        uint256 laneId = pool.protocolLane(address(protocol));
        uint256 laneLiq = pool.laneLiquidity(laneId);
        if (laneLiq < 10000) return; // Need enough for meaningful fee

        amount = bound(amount, 10000, laneLiq);
        feePct = bound(feePct, 0, 99); // 0–99% of fee

        uint256 fee = (amount * FEE_BPS) / 10000;
        if (fee == 0) return; // Dust borrow, skip

        uint256 partialFee = (fee * feePct) / 100;

        // Ensure callback has enough bond
        _ensureBonded(protocol);

        uint256 bondBefore = registry.bondOf(address(protocol));
        uint256 feeShortfall = fee - partialFee;
        uint256 actualSlash = feeShortfall > bondBefore ? bondBefore : feeShortfall;

        // Fund callback for partial fee
        poolToken.mint(address(protocol), partialFee);
        protocol.setRepayAmount(amount + partialFee);

        vm.prank(address(protocol));
        pool.flashAccess(amount, address(protocol), "");

        ghost_flashAccessCount++;
        ghost_slashCount++;
        ghost_totalFeesAccrued += partialFee;
        ghost_totalActualSlashed += actualSlash;
    }

    // ── Action: flash access (overpay treated as fee) ────────────────────

    function handler_flashAccess_overpay(uint256 protocolSeed, uint256 amount, uint256 extra)
        external
    {
        InvariantCallback protocol = _protocol(protocolSeed);
        uint256 laneId = pool.protocolLane(address(protocol));
        uint256 laneLiq = pool.laneLiquidity(laneId);
        if (laneLiq == 0) return;

        amount = bound(amount, 0, laneLiq);
        extra = bound(extra, 1, 100 ether);

        uint256 fee = (amount * FEE_BPS) / 10000;

        _ensureBonded(protocol);

        // Fund callback for fee + overpay
        poolToken.mint(address(protocol), fee + extra);
        protocol.setRepayAmount(amount + fee + extra);

        vm.prank(address(protocol));
        pool.flashAccess(amount, address(protocol), "");

        ghost_flashAccessCount++;
        ghost_totalFeesAccrued += fee + extra;
    }

    // ── Action: delegated execution (flashAccessFor) ─────────────────────

    function handler_flashAccessFor_happy(
        uint256 protocolSeed,
        uint256 executorSeed,
        uint256 amount
    ) external {
        InvariantCallback protocol = _protocol(protocolSeed);
        address executor = executors[executorSeed % executors.length];

        uint256 laneId = pool.protocolLane(address(protocol));
        uint256 laneLiq = pool.laneLiquidity(laneId);
        if (laneLiq == 0) return;

        amount = bound(amount, 0, laneLiq);
        uint256 fee = (amount * FEE_BPS) / 10000;

        _ensureBonded(protocol);

        poolToken.mint(address(protocol), fee);
        protocol.setRepayAmount(amount + fee);

        vm.prank(executor);
        pool.flashAccessFor(address(protocol), amount, address(protocol), "");

        ghost_flashAccessCount++;
        ghost_totalFeesAccrued += fee;
    }

    // ── Action: principal shortfall (should revert, no state persists) ───

    function handler_flashAccess_principalShortfall(
        uint256 protocolSeed,
        uint256 amount,
        uint256 shortfall
    ) external {
        InvariantCallback protocol = _protocol(protocolSeed);
        uint256 laneId = pool.protocolLane(address(protocol));
        uint256 laneLiq = pool.laneLiquidity(laneId);
        if (laneLiq == 0) return;

        amount = bound(amount, 1, laneLiq);
        shortfall = bound(shortfall, 1, amount);

        _ensureBonded(protocol);

        protocol.setRepayAmount(amount - shortfall);

        vm.prank(address(protocol));
        (bool ok,) = address(pool)
            .call(
                abi.encodeWithSelector(
                    ParallelPool.flashAccess.selector, amount, address(protocol), ""
                )
            );
        // Should revert (principal not returned)
        if (ok) revert("Expected principal shortfall revert");

        ghost_revertCount++;
    }

    // ── Action: claim fees ───────────────────────────────────────────────

    function handler_claimFees() external {
        uint256 receiverBefore = poolToken.balanceOf(pool.feeReceiver());
        pool.claimFees();
        uint256 claimed = poolToken.balanceOf(pool.feeReceiver()) - receiverBefore;
        ghost_totalFeesClaimed += claimed;
    }

    // ── Internal helpers ─────────────────────────────────────────────────

    function _protocol(uint256 seed) internal view returns (InvariantCallback) {
        return protocols[seed % protocols.length];
    }

    /// @dev Ensures the protocol has at least minBond bonded.
    ///      Re-bonds if slashed below threshold.
    function _ensureBonded(InvariantCallback protocol) internal {
        uint256 currentBond = registry.bondOf(address(protocol));
        if (currentBond < MIN_BOND) {
            uint256 needed = MIN_BOND - currentBond;
            paraToken.mint(address(protocol), needed);
            vm.startPrank(address(protocol));
            paraToken.approve(address(registry), needed);
            registry.bond(needed);
            vm.stopPrank();
        }
    }
}

// ─── Invariant test contract ─────────────────────────────────────────────────

contract InvariantTest is Test {
    ParallelPool public pool;
    BondRegistry public registry;
    MockToken public poolToken;
    MockToken public paraToken;
    InvariantCallback[3] public protocols;
    PoolHandler public handler;

    address public feeReceiverAddr = address(0xFEE);

    uint256 constant MIN_BOND = 1000 ether;
    uint256 constant FEE_BPS = 10;
    uint256 constant NUM_LANES = 4;
    uint256 constant SEED_DEPOSIT = 10_000 ether;

    function setUp() public {
        // ── Deploy protocol ──────────────────────────────────────────
        poolToken = new MockToken("Pool Token", "POOL");
        paraToken = new MockToken("PRLL", "PRLL");
        registry = new BondRegistry(address(paraToken));

        pool = new ParallelPool(
            address(poolToken), address(registry), MIN_BOND, FEE_BPS, NUM_LANES, feeReceiverAddr
        );
        registry.authorizePool(address(pool));

        // ── Deploy protocol callback modules ─────────────────────────
        protocols[0] = new InvariantCallback();
        protocols[1] = new InvariantCallback();
        protocols[2] = new InvariantCallback();

        for (uint256 i = 0; i < protocols.length; i++) {
            paraToken.mint(address(protocols[i]), MIN_BOND);
            vm.prank(address(protocols[i]));
            paraToken.approve(address(registry), MIN_BOND);
            vm.prank(address(protocols[i]));
            registry.bond(MIN_BOND);
        }

        // ── Authorize executors for delegated execution ──────────────
        address[2] memory execs = [address(uint160(0xE001)), address(uint160(0xE002))];
        for (uint256 i = 0; i < protocols.length; i++) {
            for (uint256 j = 0; j < execs.length; j++) {
                vm.prank(address(protocols[i]));
                pool.authorizeExecutor(execs[j], true);
            }
        }

        // ── Seed pool with initial liquidity ─────────────────────────
        poolToken.mint(address(this), SEED_DEPOSIT);
        poolToken.approve(address(pool), SEED_DEPOSIT);
        pool.deposit(SEED_DEPOSIT);

        // ── Deploy handler ───────────────────────────────────────────
        handler = new PoolHandler(
            pool, registry, poolToken, paraToken, protocols[0], protocols[1], protocols[2]
        );

        // ── Tell Foundry to only call handler functions ──────────────
        targetContract(address(handler));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  INVARIANTS — checked after every random call sequence
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev INV-1: Pool solvency — vault token balances always >= totalDeposits.
    ///      Vault balances include accrued fees, so they should always be >=.
    function invariant_poolSolvency() public view {
        uint256 totalVaultBal;
        for (uint256 i = 0; i < NUM_LANES; i++) {
            totalVaultBal += poolToken.balanceOf(pool.laneVault(i));
        }
        assertGe(totalVaultBal, pool.totalDeposits(), "INV-1 BROKEN: vaults < totalDeposits");
    }

    /// @dev INV-2: Fee accounting — vault balances minus accrued fees == availableLiquidity().
    function invariant_feeAccounting() public view {
        uint256 totalVaultBal;
        uint256 totalAccrued;
        for (uint256 i = 0; i < NUM_LANES; i++) {
            totalVaultBal += poolToken.balanceOf(pool.laneVault(i));
            totalAccrued += pool.accruedFees(i);
        }
        assertEq(
            totalVaultBal - totalAccrued,
            pool.availableLiquidity(),
            "INV-2 BROKEN: fee accounting mismatch"
        );
    }

    /// @dev INV-3: Per-lane fee bound — accruedFees[i] never exceeds the lane vault balance.
    function invariant_perLaneFeeBound() public view {
        for (uint256 i = 0; i < NUM_LANES; i++) {
            uint256 vaultBal = poolToken.balanceOf(pool.laneVault(i));
            uint256 accrued = pool.accruedFees(i);
            assertGe(vaultBal, accrued, "INV-3 BROKEN: accrued fees > vault balance on a lane");
        }
    }

    /// @dev INV-4: Lane liquidity sum — sum of per-lane liquidity == availableLiquidity().
    function invariant_laneLiquiditySum() public view {
        uint256 sumLanes;
        for (uint256 i = 0; i < NUM_LANES; i++) {
            sumLanes += pool.laneLiquidity(i);
        }
        assertEq(
            sumLanes, pool.availableLiquidity(), "INV-4 BROKEN: lane sum != availableLiquidity"
        );
    }

    /// @dev INV-5: Bond consistency — locked bonds never exceed total bonds for the callback.
    function invariant_bondConsistency() public view {
        for (uint256 i = 0; i < protocols.length; i++) {
            uint256 bond = registry.bondOf(address(protocols[i]));
            uint256 locked = registry.lockedBondOf(address(protocols[i]));
            assertGe(bond, locked, "INV-5 BROKEN: lockedBonds > bonds");
        }
    }

    /// @dev INV-6: No locked bonds outside flash access — after every handler call
    ///      completes, locked bonds should be 0 (bonds are unlocked at end of flashAccess).
    function invariant_noStaleLocks() public view {
        for (uint256 i = 0; i < protocols.length; i++) {
            assertEq(
                registry.lockedBondOf(address(protocols[i])),
                0,
                "INV-6 BROKEN: bonds still locked outside flash access"
            );
        }
    }

    /// @dev INV-7: Available liquidity >= totalDeposits.
    ///      Fees paid on top of principal mean available >= deposits.
    ///      (After claimFees, available == deposits; before, available >= deposits.)
    function invariant_availableLiqGeTotalDeposits() public view {
        assertGe(
            pool.availableLiquidity(),
            pool.totalDeposits(),
            "INV-7 BROKEN: availableLiquidity < totalDeposits"
        );
    }

    /// @dev INV-8: Ghost accounting — totalDeposited - totalWithdrawn == totalDeposits.
    ///      Uses ghost variables from the handler to cross-check pool accounting.
    function invariant_ghostDepositTracking() public view {
        assertEq(
            handler.ghost_totalDeposited() + SEED_DEPOSIT - handler.ghost_totalWithdrawn(),
            pool.totalDeposits(),
            "INV-8 BROKEN: ghost deposit tracking mismatch"
        );
    }

    /// @dev INV-9: Fee receiver balance equals total fees claimed (no other inflows).
    function invariant_feeReceiverBalance() public view {
        assertEq(
            poolToken.balanceOf(feeReceiverAddr),
            handler.ghost_totalFeesClaimed(),
            "INV-9 BROKEN: feeReceiver balance mismatch"
        );
    }

    /// @dev INV-10: Accrued fee conservation.
    ///      totalFeesAccrued == totalFeesClaimed + sum(accruedFees).
    function invariant_feeConservation() public view {
        uint256 totalAccrued;
        for (uint256 i = 0; i < NUM_LANES; i++) {
            totalAccrued += pool.accruedFees(i);
        }
        assertEq(
            handler.ghost_totalFeesAccrued(),
            handler.ghost_totalFeesClaimed() + totalAccrued,
            "INV-10 BROKEN: fee conservation mismatch"
        );
    }

    /// @dev INV-11: Vault balances equal principal + unclaimed fees.
    ///      sum(vault balances) == totalDeposits + sum(accruedFees).
    function invariant_vaultBalanceDecomposition() public view {
        uint256 totalVaultBal;
        uint256 totalAccrued;
        for (uint256 i = 0; i < NUM_LANES; i++) {
            totalVaultBal += poolToken.balanceOf(pool.laneVault(i));
            totalAccrued += pool.accruedFees(i);
        }
        assertEq(
            totalVaultBal,
            pool.totalDeposits() + totalAccrued,
            "INV-11 BROKEN: vault balances != deposits + accrued fees"
        );
    }

    /// @dev INV-12: Pool contract should not retain tokens (all liquidity sits in lane vaults).
    function invariant_poolHoldsNoTokens() public view {
        assertEq(poolToken.balanceOf(address(pool)), 0, "INV-12 BROKEN: pool contract holds tokens");
    }

    /// @dev INV-13: Slashing conservation — slashReceiver balance equals total actual slashed.
    function invariant_slashReceiverBalance() public view {
        address receiver = registry.slashReceiver();
        assertEq(
            paraToken.balanceOf(receiver),
            handler.ghost_totalActualSlashed(),
            "INV-13 BROKEN: slashReceiver balance mismatch"
        );
    }

    /// @dev INV-14: Only tracked LPs + seed depositor contribute to totalDeposits.
    ///      sum(deposits[seed + lps]) == totalDeposits.
    function invariant_totalDepositsMatchesSumOfTrackedLps() public view {
        uint256 sum = pool.deposits(address(this));
        sum += pool.deposits(address(uint160(0xA001)));
        sum += pool.deposits(address(uint160(0xA002)));
        sum += pool.deposits(address(uint160(0xA003)));
        assertEq(sum, pool.totalDeposits(), "INV-14 BROKEN: deposits sum mismatch");
    }

    // ── Call summary (for debugging / observability) ─────────────────────

    function invariant_callSummary() public view {
        // This invariant never fails — it just logs ghost counters so
        // `forge test -vv` shows how many of each action were exercised.
        // Uncomment the console.logs below if you want verbose output:
        //
        // console.log("Deposits:", handler.ghost_totalDeposited());
        // console.log("Withdraws:", handler.ghost_totalWithdrawn());
        // console.log("Flash accesses:", handler.ghost_flashAccessCount());
        // console.log("Slashes:", handler.ghost_slashCount());
        // console.log("Fees claimed:", handler.ghost_totalFeesClaimed());
    }
}
