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

## Monad Mainnet Deployment

**Chain:** Monad Mainnet (chain ID 143) | **Deployer:** `0xf11e7F83B59aD1dF23EfF9Bf4A5E2b4b3ab756Aa`

| Contract | Address |
|----------|---------|
| Pool Token (POOL) | [`0x0c6ADF5E204C0Cf5B5c97442464d4c25a5155b4F`](https://monadscan.com/address/0x0c6ADF5E204C0Cf5B5c97442464d4c25a5155b4F) |
| PRLL Token | [`0x0d31FF18ff8B26F3861737bFd83Bd4617AA1e3F5`](https://monadscan.com/address/0x0d31FF18ff8B26F3861737bFd83Bd4617AA1e3F5) |
| BondRegistry | [`0xD11ce2204499367f58d12E0f2364Ac0b4c8f79C8`](https://monadscan.com/address/0xD11ce2204499367f58d12E0f2364Ac0b4c8f79C8) |
| **ParallelPool** | [**`0xa9bb3620c2335e30DC8e6dAd55440400EDd7a366`**](https://monadscan.com/address/0xa9bb3620c2335e30DC8e6dAd55440400EDd7a366) |
| MockSwapModule | [`0xE18911EB24450Bc5319598A885a85d7B16EC6bdE`](https://monadscan.com/address/0xE18911EB24450Bc5319598A885a85d7B16EC6bdE) |
| MockArbModule | [`0xA7ddE29B5Abd8DB7F6663CCA82C2812728f5E04a`](https://monadscan.com/address/0xA7ddE29B5Abd8DB7F6663CCA82C2812728f5E04a) |
| MockBadModule | [`0x8Afb2Fd8cADD2a51DA81cCCa84c15113E632CB6a`](https://monadscan.com/address/0x8Afb2Fd8cADD2a51DA81cCCa84c15113E632CB6a) |

**Config:** 4 lanes, 10 bps fee, 1000 PRLL min bond | **Slash receiver:** `0x...dEaD` (burn)

All 3 demo scenarios (swap, arb, proportional slash) executed successfully on-chain. See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for full tx hashes and on-chain proof.

### Verified Contracts

All contracts are verified on 3 block explorers:

- [Monadscan](https://monadscan.com/address/0xa9bb3620c2335e30DC8e6dAd55440400EDd7a366#code) (Etherscan)
- [SocialScan](https://monad.socialscan.io/address/0xa9bb3620c2335e30DC8e6dAd55440400EDd7a366#code)
- [MonadVision](https://monadvision.com/address/0xa9bb3620c2335e30DC8e6dAd55440400EDd7a366?tab=Contract) (BlockVision)

### Prerequisites

**Monad Foundry** is required for accurate gas estimation on Monad. Standard Foundry underestimates gas because Monad charges based on `gas_limit` (not `gas_used`) and has different opcode pricing. See [Monad Foundry docs](https://docs.monad.xyz/tooling-and-infra/toolkits/monad-foundry).

```bash
curl -L https://raw.githubusercontent.com/category-labs/foundry/monad/foundryup/install | bash
foundryup --network monad
```

### Deploy & Run Demo

```bash
cp .env.example .env
# Set MONAD_MAINNET_RPC_URL, ACCOUNT_NAME, DEPLOYER_ADDRESS

./script/deploy-mainnet.sh    # Deploy contracts
./script/demo-mainnet.sh      # Run demo (swap, arb, slash)
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

- **Contract**: [`0x6833D899649D426e8E4712589F592814c6fE7777`](https://nad.fun/tokens/0x6833D899649D426e8E4712589F592814c6fE7777) — launched on [nad.fun](https://nad.fun)
- **Utility**: Bond collateral for pool access
- **Slashing**: Slashed on **fee shortfall** (non-reverting) and sent to a receiver (defaults to `0xdead`)

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

## Autonomous Agent (LLM-Powered)

ParallelPool includes an **autonomous off-chain agent** that uses GPT-4o-mini to reason about pool state, select strategies, and execute flash accesses — all with hard-coded safety limits the LLM cannot override.

**Key features:**
- **Lane-aware reasoning** — LLM picks the least-utilized lane for better parallelism
- **Slash-and-adapt** — detects on-chain slashing, feeds it back to the LLM, which learns to avoid risky strategies
- **9 hard safety checks** — max borrow, bond floor, gas ceiling, circuit breaker, etc.
- **ERC-8004 identity & reputation** — on-chain agent registration + 3rd-party reputation via a separate monitor wallet
- **3-wallet isolation** — agent, monitor, and deployer wallets are fully separated

```bash
cd agent
cp .env.example .env   # Set OPENAI_API_KEY, AGENT_PRIVATE_KEY, MONITOR_PRIVATE_KEY
npm install
npm run dev
```

Full architecture: **[docs/AGENT_ARCHITECTURE.md](docs/AGENT_ARCHITECTURE.md)**

---

## Links

- **Hackathon**: [Moltiverse](https://moltiverse.dev/)
- **Monad**: [monad.xyz](https://monad.xyz)
- **Docs**: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | [docs/AGENT_ARCHITECTURE.md](docs/AGENT_ARCHITECTURE.md)

---

*Built for the Moltiverse Hackathon (Feb 2-18, 2026)*
