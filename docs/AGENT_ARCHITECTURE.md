# ParallelPool Autonomous Agent — Architecture

An LLM-powered autonomous agent that monitors on-chain pool state and external market signals, uses AI reasoning to decide when and how to execute flash accesses through ParallelPool, and maintains a verifiable on-chain identity and reputation via ERC-8004 on Monad.

---

## Overview

```
                    Off-Chain Agent (TypeScript)
    ┌───────────────────────────────────────────────────┐
    │                                                   │
    │   Monitor ──> LLM Brain ──> Safety ──> Executor   │
    │      │        (GPT-4o-mini)    │          │       │
    │      │            │            │          │       │
    │   CoinGecko   Memory       Hard caps   viem tx   │
    │   MON/USD   (slash-aware)  (LLM can't  signing   │
    │              history        override)   ──────┐   │
    │                                              │   │
    │   Identity (ERC-8004)                   Slash │   │
    │   Register at startup                   Detect│   │
    │                                         bond  │   │
    │   ┌─────────────────────┐              before │   │
    │   │ Monitor Wallet (2nd)│              /after │   │
    │   │ 3rd-party reputation│                    │   │
    │   │ giveFeedback()      │◄───────────────────┘   │
    │   └─────────────────────┘                        │
    └──────────────────────┬────────────────────────────┘
                           │
                    Monad Blockchain
    ┌──────────────────────┴────────────────────────────┐
    │                                                   │
    │   ParallelPool ── BondRegistry                    │
    │       │                                           │
    │   LaneVault x4 (parallel execution)               │
    │       │                                           │
    │   MockSwapModule ── MockArbModule ── MockBadModule │
    │   (safe)             (safe)         (slash!)      │
    │                                                   │
    │   ERC-8004 Identity Registry                      │
    │   ERC-8004 Reputation Registry                    │
    └───────────────────────────────────────────────────┘
```

---

## Decision Flow (each cycle, ~15 seconds)

### 1. Monitor

Reads on-chain state via Monad RPC (parallel individual calls):
- Lane liquidity for all 4 lanes
- Bond balance and locked bond for the agent's wallet
- Current gas price
- MON/USD price from CoinGecko (with input validation)

### 2. LLM Reasoning (Lane-Aware + Slash-Adaptive)

Sends a structured prompt to GPT-4o-mini containing:
- **Per-lane utilization** — liquidity per lane with percentage of total, so the LLM can prefer less-utilized lanes
- Price signal (current price, delta since last cycle)
- **Last 8 execution records** including slash events with bond delta
- **Slash summary** — last slash cycle, cycles since, bond impact
- **Risk context** — cycles since last "risky" execution, nudge to occasionally test BadModule

The LLM is instructed to:
1. **Reason about lane selection**: "Lane 2 has 15% utilization, I'll route there for better parallelism"
2. **Learn from slash events**: "Last cycle I was slashed on lane 2, reducing position size and switching to safe strategies"
3. **Periodically test risk**: Every ~10 cycles, use the "risky" strategy with a small amount to demonstrate slash-and-adapt behavior

The LLM returns a structured JSON decision:
```json
{
  "action": "execute",
  "reasoning": "MON price rose 2.49%. Lane 2 has lowest utilization at 15%. Last slash was 8 cycles ago — bond recovered. Confident in arb opportunity.",
  "strategy": "arb",
  "amount": "500000000000000000000",
  "confidence": 0.82
}
```

Available strategies: `"arb"` (safe arbitrage), `"swap"` (safe rebalance), `"risky"` (intentionally triggers slash via BadModule).

### 3. Safety Validation

The LLM's decision passes through 9 hard-coded checks that the LLM cannot override:

| Check | Limit | Purpose |
|---|---|---|
| Max borrow per cycle | 1,000 POOL | Prevent oversized positions |
| Daily borrow limit | 5,000 POOL | Cumulative exposure cap |
| Bond floor | 500 PRLL | Halt if bond too low |
| Gas ceiling | 500 gwei | Skip if gas is abnormal |
| Min confidence | 0.6 | Reject low-conviction decisions |
| Lane utilization | 80% max | Don't drain any single lane |
| Positive amount | > 0 | Sanity check |
| Circuit breaker | 3 consecutive failures | Full halt |
| **Risky strategy cap** | **100 POOL max** | **Limit slash exposure from BadModule** |

If any check fails, the decision is rejected and logged. The risky strategy cap ensures the LLM can never cause excessive bond loss even if it chooses BadModule.

### 4. Execution

If safety passes, the agent calls the strategy module on-chain:
- `swapModule.execute(amount)` — safe swap strategy
- `arbModule.execute(amount)` — safe arbitrage strategy
- `badModule.execute(amount)` — intentionally triggers slash (risky strategy)
- Simulates the transaction first (catches reverts before spending gas)
- Waits for receipt and extracts gas used

**Slash detection**: After every execution, the agent reads bond balance before vs. after. If bond decreased, the execution is marked as `slashed: true` with the bond delta, and this information is fed back to the LLM in subsequent cycles.

The agent wallet is **allowlisted** — it can only call these three module functions. No arbitrary contract calls.

### 5. Reputation (3rd-Party Monitor Wallet)

After each execution, a **separate monitor wallet** submits feedback to the ERC-8004 Reputation Registry. This is a key design choice:

- **Why a separate wallet?** ERC-8004 reputation is more credible when submitted by an independent observer, not the agent rating itself. The monitor wallet watches the agent's transactions and independently attests to outcomes.
- `giveFeedback(agentId, score, "flashAccess", strategy)`
- Score: **+100** for success, **0** for regular failure, **-50** for slash events
- Tag2 includes slash info: e.g., `"risky/slashed"` vs `"arb"`
- Feedback URI contains JSON context (cycle, strategy, success, slashed, submitter)
- If `MONITOR_PRIVATE_KEY` is not set, falls back to agent self-reporting (less credible but functional)

### 6. Memory

Records the outcome in a rolling history (last 50 cycles), including **slash events** with bond deltas. This history is included in the next cycle's LLM prompt, allowing the agent to:
- **Recognize and learn from slash events**: "I was slashed 3 cycles ago, adjusting strategy..."
- Adapt strategy selection based on what has worked and what caused losses
- Reason about its performance trajectory and risk tolerance
- Know when it's "safe" to test risky strategies again (cycles since last slash)

---

## ERC-8004 Integration

### Identity Registry (`0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`)

At startup, the agent registers on the ERC-8004 Identity Registry by minting an ERC-721 NFT. The agent card (stored as a base64 data URI on-chain) describes:

```json
{
  "type": "https://eips.ethereum.org/EIPS/eip-8004#registration-v1",
  "name": "ParallelPool Liquidity Agent",
  "description": "Autonomous AI agent that manages flash access strategies across ParallelPool's parallel lanes on Monad.",
  "services": [{ "name": "web", "endpoint": "https://github.com/john-lawniczak/Parallel-Pool" }],
  "active": true,
  "supportedTrust": ["reputation"]
}
```

This makes the agent discoverable on 8004scan.io and agentscan.info.

### Reputation Registry (`0x8004BAa17C55a88189AE136b182e5fdA19dE9b63`)

After each execution cycle, the **monitor wallet** (a separate 3rd-party observer) submits on-chain reputation feedback:
- `tag1`: "flashAccess" (operation type)
- `tag2`: "arb", "swap", "risky", or "risky/slashed" (strategy + slash status)
- `value`: +100 (success), 0 (failure), or -50 (slashed)
- `feedbackURI`: Base64-encoded JSON with execution context (cycle, strategy, success, slashed, submitter)

**Why 3rd-party feedback matters:** An agent rating itself is inherently biased. By using a separate monitor wallet, the reputation data is more credible — the monitor independently observes on-chain outcomes and submits its own attestation. This aligns with ERC-8004's design for trust-building between agents and protocols.

---

## Security Hardening

Designed per [OWASP Top 10 for Agentic AI](https://medium.com/@vito.rallo/owasp-dropped-a-top-10-for-agentic-ai-heres-what-actually-matters-a0b95ce32c16) principles.

### Private Key Management
- `.env` is in `.gitignore` — never committed
- Dedicated hot wallet with minimal funds (gas only)
- Private keys never included in LLM prompts

### LLM Prompt Hardening
- System prompt restricts output to structured JSON only
- Explicit instructions: never output shell commands, URLs, or config modifications
- Response validation rejects suspicious content (curl, wget, bash, private key references)
- JSON schema validation on every response

### Input Sanitization
- CoinGecko price data validated: type checks, range checks ($0.0001–$100,000), timeout (5s)
- Absurd values rejected before reaching the prompt
- On failure, falls back to last known price with no delta

### Wallet Isolation (3 wallets)
- **Agent wallet**: Executes strategies, holds only gas MON
- **Monitor wallet**: Submits 3rd-party reputation feedback, independent from agent
- **Deployer wallet**: Never used by agent (separation of concerns)
- Hardcoded allowlist: agent can only call `swapModule.execute()`, `arbModule.execute()`, and `badModule.execute()`
- Simulate-before-send: transaction is simulated first to catch reverts

### Circuit Breaker
- 3 consecutive execution failures trigger a full halt
- Agent stops and logs the failure chain
- Requires manual restart after investigation

---

## File Structure

```
agent/
  package.json          # viem, openai, dotenv
  tsconfig.json
  .env.example          # Placeholder config (no real secrets)
  .gitignore            # .env, node_modules, dist
  src/
    index.ts            # Entry: ERC-8004 register → main loop
    config.ts           # Addresses, ABIs, safety caps, LLM config
    types.ts            # Shared type definitions
    monitor.ts          # On-chain state + CoinGecko price
    llm.ts              # Prompt builder, OpenAI call, response parser
    safety.ts           # 9 hard checks, circuit breaker, daily tracking
    executor.ts         # Allowlisted tx execution via viem
    identity.ts         # ERC-8004 Identity Registry
    reputation.ts       # ERC-8004 Reputation Registry
    memory.ts           # Rolling execution history
    logger.ts           # Rich ANSI terminal output for demo
```

**Dependencies:** `viem` (Monad RPC + signing), `openai` (GPT-4o-mini), `dotenv` (config). Three total.

---

## Running the Agent

```bash
cd agent
cp .env.example .env
# Edit .env:
#   OPENAI_API_KEY=sk-...
#   AGENT_PRIVATE_KEY=0x... (dedicated hot wallet with MON for gas)
#   MONITOR_PRIVATE_KEY=0x... (separate wallet for 3rd-party reputation)
#   MONAD_RPC_URL=https://testnet-rpc.monad.xyz

npm install
npm run dev
```

The agent prints rich terminal output showing its full reasoning chain each cycle — this output is designed to be recorded directly as the demo video content.

---

## Demo Output (example — showing slash-and-adapt cycle)

```
══════════════════════════════════════════════════════
  ParallelPool Liquidity Agent v1.0
  ERC-8004 Agent ID: #1247 (registered on Monad)
  Wallet: 0xABC...DEF
  Monitor wallet: 0x123...789 (3rd-party reputation)
══════════════════════════════════════════════════════

[22:15:03] === CYCLE 11 ===
  Pool State (per-lane breakdown):
    Lane 0: 2,500 POOL (25.0%) | Lane 1: 2,500 POOL (25.0%)
    Lane 2: 2,500 POOL (25.0%) | Lane 3: 2,500 POOL (25.0%)
    Bond: 999.5 PRLL (0 locked) | Gas: 103 gwei
  Price Signal:
    MON/USD: $2.41 -> $2.43 (+0.83%)

  LLM Reasoning:
    "10 consecutive successful cycles with no slash events.
     It's time to test slash resilience with a small risky execution.
     Lane 0 has good liquidity at 25%. Using BadModule with minimal
     50 POOL to demonstrate adaptive behavior."

  >> Decision: EXECUTE | strategy=risky | amount=50 POOL | confidence=0.70
  Safety: PASS [+amount | +daily | +bond | +gas | +conf | +lane | +pos | +cb | +risky-cap]

  ⚠ SLASHED! Strategy "risky" triggered bond slash
    Bond: 999.5 → 999.45 PRLL (lost 0.05 PRLL)
    Agent will adapt strategy in next cycles...

  SLASHED: tx 0xf52...45f | strategy: risky | bond delta: -50000000000000000
  Reputation: monitor:0x123...789 | score=-50 | tag=flashAccess/risky/slashed
  Memory: 9/11 successful (82%) | slashes: 1 | daily: 2,550/5,000 POOL

[22:15:18] === CYCLE 12 ===
  Pool State (per-lane breakdown):
    Lane 0: 2,500 POOL (25.0%) | Lane 1: 2,500 POOL (25.0%)
    Lane 2: 2,500 POOL (25.0%) | Lane 3: 2,500 POOL (25.0%)
    Bond: 999.45 PRLL (0 locked) | Gas: 105 gwei
  Price Signal:
    MON/USD: $2.43 -> $2.45 (+0.82%)

  ⚠ Last slash: cycle 11 (1 cycle ago) — bond lost: -50000000000000000

  LLM Reasoning:
    "I was slashed last cycle using the risky strategy — my bond dropped
     from 999.5 to 999.45 PRLL. Switching back to safe strategies.
     Lane 2 has equal utilization but price movement suggests a moderate
     swap opportunity. Reducing position size to 300 POOL as a
     conservative recovery measure."

  >> Decision: EXECUTE | strategy=swap | amount=300 POOL | confidence=0.75
  Safety: PASS [+amount | +daily | +bond | +gas | +conf | +lane | +pos | +cb | +risky-cap]

  EXECUTED: tx 0xabc...def | gas: 142,391 | strategy: swap
  Reputation: monitor:0x123...789 | score=100 | tag=flashAccess/swap
  Memory: 10/12 successful (83%) | slashes: 1 | daily: 2,850/5,000 POOL
```
