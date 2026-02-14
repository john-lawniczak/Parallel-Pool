# ParallelPool

**Shared liquidity for parallel DeFi**

ParallelPool is a **shared-liquidity primitive** designed for parallel EVMs like Monad. It’s best understood as the parallel-execution analog of the standard flash loan interface (ERC-3156): concurrent shared liquidity access with **bonded accountability** and deterministic, per-tx invariant enforcement.

---

## Abstract
ParallelPool defines a minimal interface + reference implementation for **protocol-facing flash liquidity** where:
- **principal shortfall** → tx reverts (pool solvency protected)
- **fee shortfall** → tx succeeds, but the caller is **slashed** (penalty persists)
- **bond locking** prevents “unbond during callback” fee-evasion exploits

## The Problem

On Ethereum, liquidity is fragmented:
- Protocol A has Pool A
- Protocol B has Pool B
- Capital inefficient, duplicated liquidity

## The Solution

On Monad's parallel EVM, we can share:
- One pool, many protocols
- Concurrent access in the same block
- Bonded accountability (misbehave = slashed)

---

## How It Works

```
1. BOND     → Protocol bonds $PRLL tokens
2. ACCESS   → Protocol calls flashAccess(amount, callback)
3. USE      → Callback executes arbitrary logic
4. RETURN   → Must return tokens + fee in same tx
5. CHECK    → Pool verifies invariant
6. RESULT   → Fee unpaid = SLASHED | Principal unpaid = REVERT
```

---

## Why this is a “new primitive”
Classic primitives like ERC‑3156 flash loans assume **sequential execution**. On Monad, **multiple independent transactions can execute concurrently**, which creates a new design space: **shared liquidity access** with explicit, deterministic conflict behavior.

ParallelPool is intentionally small (pool + bond registry) so other protocols can integrate it like infrastructure, not an app.

## Quick Start

```bash
# Clone
git clone --recurse-submodules https://github.com/john-lawniczak/Parallel-Pool.git
cd Parallel-Pool

# Install dependencies (if submodules not cloned above)
forge install

# Run tests (116 tests: unit, fuzz, invariant)
forge test --offline

# Run demo (local)
forge script script/Demo.s.sol -vvvv
```

---

## Monad Testnet

```bash
# 1) Create env file
cp .env.example .env

# 2) Set MONAD_RPC_URL and ACCOUNT_NAME in .env
#    (Create/import the keystore first: `cast wallet import $ACCOUNT_NAME --interactive`)

# 3) Deploy contracts
./script/deploy-testnet.sh

# 4) Run demo transactions on testnet
./script/demo-testnet.sh
```

---

## Contracts

| Contract | Description |
|----------|-------------|
| `ParallelPool.sol` | Main pool with flash access + invariant checks |
| `BondRegistry.sol` | Bond/unbond/slash mechanics (Ownable2Step) |
| `LaneVault.sol` | Minimal per-lane vault for parallel-safe `balanceOf` slots |
| `MockSwapModule.sol` | Demo: successful flash user |
| `MockArbModule.sol` | Demo: another successful user |
| `MockBadModule.sol` | Demo: fails invariant, gets slashed |

---

## Token: $PRLL

- **Utility**: Bond collateral for pool access
- **Slashing**: Slashed on **fee shortfall** (non-reverting) and sent to a receiver (defaults to `0xdead`)
- **Launch**: nad.fun

---

## Why Monad?

This only works on a parallel EVM:

| Chain | Execution | Concurrent Pool Access |
|-------|-----------|------------------------|
| Ethereum | Sequential | No |
| **Monad** | **Parallel** | **Yes** |

### Security note
Naively bonding isn’t enough: without **bond locking during flash access**, a borrower can unbond during the callback and evade slashing. ParallelPool explicitly locks bond for the duration of `flashAccess` and includes regression tests for this exploit.

---

## Links

- **Hackathon**: [Moltiverse](https://moltiverse.dev/)
- **Monad**: [monad.xyz](https://monad.xyz)
- **Docs**: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

---

*Built for the Moltiverse Hackathon (Feb 2-18, 2026)*
