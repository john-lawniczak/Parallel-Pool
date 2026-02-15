# ParallelPool Architecture

## Overview

ParallelPool is a shared liquidity primitive designed for parallel EVMs. It enables multiple protocols to access the same liquidity pool concurrently with bonded accountability.

**Key innovation:** Liquidity is split across N **lane vaults** — separate contracts with isolated `balanceOf` storage slots. Flash-access transactions routed to different lanes touch disjoint ERC-20 state and can execute concurrently on Monad without conflict.

## Lane Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                      PARALLELPOOL (router)                           │
│                                                                      │
│  protocolLane(addr) = uint160(addr) % NUM_LANES                     │
│                                                                      │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────┐        │
│  │ LaneVault │  │ LaneVault │  │ LaneVault │  │ LaneVault │        │
│  │  lane 0   │  │  lane 1   │  │  lane 2   │  │  lane 3   │        │
│  │           │  │           │  │           │  │           │        │
│  │ balanceOf │  │ balanceOf │  │ balanceOf │  │ balanceOf │        │
│  │ [vault0]  │  │ [vault1]  │  │ [vault2]  │  │ [vault3]  │        │
│  └───────────┘  └───────────┘  └───────────┘  └───────────┘        │
│                                                                      │
│  Per-lane reentrancy guards: _laneLocked[laneId]                    │
└──────────────────────────────────────────────────────────────────────┘
```

### Why lanes?

Without lanes, every `flashAccess` touches `balanceOf[pool]` — a single hot storage slot. On a parallel EVM, concurrent transactions that read/write the same slot **conflict and serialize**. This undermines the "parallel-native" claim.

With lanes:
- Each vault has a **separate** `balanceOf` slot in the ERC-20 contract
- Each lane has its own **reentrancy guard** (`_laneLocked[laneId]`)
- Two protocols assigned to different lanes touch **zero shared state**
- Monad can execute them **truly in parallel**

### Parallelism guarantee

> Parallelism is **per-lane**: callers on different lanes never conflict. Callers assigned to the same lane may still serialize.

Lane assignment is deterministic: `laneId = uint160(protocol) % numLanes`. Protocols don't choose their lane — it's derived from their address. This makes conflict behavior predictable and auditable.

## Contract Hierarchy

```
┌─────────────────────────────────────────────────────────────────┐
│                         USER/PROTOCOL                            │
└─────────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴─────────┐
                    │                   │
                    ▼                   ▼
┌─────────────────────────┐   ┌─────────────────────────┐
│      BondRegistry       │   │      ParallelPool       │
│                         │   │                         │
│  - bond()               │◄──│  - flashAccess()        │
│  - unbond()             │   │  - deposit()            │
│  - lockBond()           │   │  - withdraw()           │
│  - unlockBond()         │   │  - protocolLane()       │
│  - slash()              │   │  - laneVault()          │
│  - isBonded()           │   │  - laneLiquidity()      │
└─────────────────────────┘   └────────────┬────────────┘
                                           │
                              ┌────────────┼────────────┐
                              │            │            │
                              ▼            ▼            ▼
                        ┌──────────┐ ┌──────────┐ ┌──────────┐
                        │LaneVault │ │LaneVault │ │LaneVault │
                        │  lane 0  │ │  lane 1  │ │  lane N  │
                        └──────────┘ └──────────┘ └──────────┘
                                           │
                                           ▼
                              ┌─────────────────────────┐
                              │  IFlashAccessCallback   │
                              │                         │
                              │  onFlashAccess(         │
                              │    token, amount, fee,  │
                              │    repayTo, data)       │
                              └─────────────────────────┘
```

## Flash Access Flow

```
1. Caller calls pool.flashAccess(amount, callback, data)
2. Pool computes lane: laneId = protocolLane(msg.sender)
3. Per-lane reentrancy check (_laneLocked[laneId])
4. Pool checks bond requirement via BondRegistry
5. Pool checks lane vault has sufficient liquidity
6. Pool locks bond for duration (prevents unbond exploit)
7. Lane vault transfers tokens to callback
8. Pool calls callback.onFlashAccess(token, amount, fee, vaultAddress, data)
9. Callback executes arbitrary logic
10. Callback must transfer (amount + fee) to vaultAddress (the lane vault)
11. Pool checks vault balance invariants:
    - principal not returned → REVERT (pool solvency)
    - fee not paid → SLASH caller's bond (no revert, penalty persists)
12. Pool unlocks bond
13. Emit FlashAccess event with laneId
```

**Important:** The callback receives `repayTo` (the lane vault address) and MUST send tokens there — not to `msg.sender` (the pool). This ensures the vault's `balanceOf` slot is the only state that changes, enabling true parallel execution.

## Invariants

1. **Pool Solvency**: After flash access, vault balance >= pre-access balance
2. **Bond Requirement**: Only bonded users can access flash liquidity
3. **Atomic Execution**: Each flash access is self-contained in one transaction
4. **Fee Enforcement**: Fee shortfalls trigger slashing without reverting
5. **Bond Locking**: Bond is locked during `flashAccess` to prevent unbond-during-callback exploit
6. **Lane Isolation**: Each lane vault is a separate contract with independent state
7. **Fee Accounting**: `sum(vault balances) - sum(accruedFees) == availableLiquidity()`
8. **Per-lane Fee Bound**: `accruedFees[i] <= vault[i].balanceOf` for every lane
9. **No Stale Locks**: `lockedBonds[user] == 0` outside active flash access
10. **Available >= Deposits**: `availableLiquidity() >= totalDeposits` (fees add surplus)

## Parallel Safety

The design is parallel-safe because:

1. **Lane isolation** — different lanes touch different vault contracts (disjoint `balanceOf` slots)
2. **Per-lane reentrancy** — `_laneLocked[laneId]` is independent per lane
3. **Atomic invariants** — checks are per-transaction on a single vault
4. **No global ordering** — outcome doesn't depend on tx order
5. **Deterministic conflicts** — if demand > lane supply, rejects deterministically
6. **No shared hot slots** — pool contract itself holds no tokens during flash access

## Security Notes

### Bond locking prevents fee-evasion

Naive designs that only check `isBonded()` at the start are vulnerable: a borrower can **unbond during the callback** and evade slashing for fee underpayment.

ParallelPool mitigates this by having the pool:
- Lock `minBond` in `BondRegistry` before transferring funds / calling the callback
- Prevent `unbond()` of locked amounts
- Unlock after the call (or clamp unlock if slashed to zero)

### Callback must repay to lane vault

The `repayTo` parameter in `onFlashAccess` points to the specific lane vault. This is critical: if callbacks sent tokens back to the pool contract, the pool's `balanceOf` would become a hot slot shared across all lanes, destroying parallel safety.

### Callback accountability

`flashAccess` enforces that `callback == msg.sender` OR the caller has registered the callback via `registerCallback()`. This prevents a protocol from naming an arbitrary contract as callback to shift blame.

For delegated execution, `flashAccessFor(protocol, amount, callback, data)` allows an authorized executor (`authorizeExecutor()`) to submit on behalf of a bonded protocol. Bond checks, lane assignment, and slashing all reference the **protocol**, not the executor.

## Fee Routing

Fees are tracked per-lane using a **pull pattern**:

- During `flashAccess`, any fees actually paid by the callback **accrue in the lane vault** (`accruedFees[laneId]`).
- Anyone can later call `claimFees()` to sweep accrued fees from all lanes to `feeReceiver`.
- Overpayments (callback returns more than `principal + fee`) are treated as fees and accrue the same way.

This pattern matters on Monad because it prevents (a) a reverting/blacklisted `feeReceiver` from blocking flash access, and (b) cross-lane serialization that a “push fees to `feeReceiver` every flash” design would introduce.

## Proportional Slashing

Fee shortfalls result in a slash **proportional to the shortfall**, not the full bond:

```
actualSlash = min(feeShortfall, currentBond)
```

The slashed PRLL is sent to the dead address (`0x...dEaD`). The transaction does **not** revert — pool solvency is preserved (principal was returned), and the penalty is recorded on-chain via `Slashed` and `FlashAccess` events.

## Testing

The test suite provides three layers of coverage:

### Unit tests (88 tests)
Deterministic tests covering every contract function, error path, edge case, and exploit scenario. Includes callback accountability, delegated execution, fee rounding, proportional slashing, bond locking, reentrancy prevention, fee-on-transfer accounting, flash-active guard, and constructor validation.

### Fuzz tests (13 tests)
Property-based tests with randomized inputs. Each property is tested across 256+ runs with Foundry's built-in fuzzer. Covers deposit/withdraw round-trips, fee calculations, slashing proportionality, lane assignment determinism, and the pool solvency invariant.

### Invariant tests (15 invariants, 1M+ calls)
Stateful property-based tests using a **handler** contract that exposes 8 bounded protocol actions (deposit, withdraw, flash access happy/overpay/partial-fee/principal-shortfall, flashAccessFor, claimFees). Foundry calls these in random sequences of 500 calls per run, 256 runs per invariant. All invariants (1–10 above) are verified to hold after every random action sequence.

Run all tests:
```
forge test --offline
```

## Mainnet Deployment

The full system has been deployed and demonstrated on **Monad Mainnet (chain 143)**. See [DEPLOYMENT.md](./DEPLOYMENT.md) for:
- All contract addresses and deploy tx hashes
- Lane vault addresses
- Three on-chain demo transactions proving happy-path fee routing and proportional slashing
- Reproduction instructions

## Autonomous Agent

An LLM-powered off-chain agent operates on top of the deployed contracts, using GPT-4o-mini to reason about lane utilization, market signals, and its own execution history (including slash events) to autonomously execute flash access strategies. The agent registers an on-chain identity and builds verifiable reputation via ERC-8004.

See [AGENT_ARCHITECTURE.md](./AGENT_ARCHITECTURE.md) for the full design.
