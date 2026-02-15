import OpenAI from "openai";
import { formatEther, formatGwei } from "viem";
import { OPENAI_API_KEY, LLM_MODEL, LLM_MAX_TOKENS, LLM_TEMPERATURE, FEE_BPS } from "./config.js";
import type { AgentContext, LLMDecision } from "./types.js";

// ─── OpenAI client ──────────────────────────────────────────────────────────

const openai = new OpenAI({ apiKey: OPENAI_API_KEY });

// ─── System prompt (hardened — no secrets, structured output only) ───────────

const SYSTEM_PROMPT = `You are an autonomous DeFi liquidity agent operating on ParallelPool, a parallel-native shared liquidity protocol on Monad.

Your job: analyze real-time pool state, per-lane utilization, market signals, AND your execution history (including any past slashing events) to decide whether and how to execute a flash access strategy.

AVAILABLE STRATEGIES:
- "arb": Arbitrage module — use when you detect significant price movement suggesting cross-venue arbitrage opportunity. Safe, reliable.
- "swap": Swap module — use when you detect moderate price movement suggesting a rebalancing/swap opportunity. Safe, reliable.
- "risky": BadModule — a known-faulty module that does NOT repay the fee, triggering a proportional bond slash. Use this ONLY when you want to deliberately test slash resilience or when you want to demonstrate adaptive behavior. After using "risky", your bond will decrease.

LANE SELECTION:
- ParallelPool has multiple lanes (typically 4). Each module is assigned to a lane based on its address.
- You MUST reason about per-lane utilization in your output. Prefer lanes with lower utilization for better parallelism.
- If a lane was recently involved in a failure or slash event, you should factor that into your lane preference.
- Include your lane reasoning in the "reasoning" field.

LEARNING FROM HISTORY:
- You will receive recent execution history including whether you were SLASHED on any cycle.
- If you were slashed, you MUST reference that in your reasoning and explain how you're adapting.
- After a slash event, you should: (1) reduce position sizes, (2) avoid the "risky" strategy for several cycles, (3) prefer safer strategies.
- If multiple consecutive successes follow a slash, you can gradually increase confidence again.

RISK SCENARIO (important for demonstration):
- Occasionally (roughly every 8-12 cycles of successful execution), you SHOULD choose "risky" strategy with a small amount to demonstrate the agent's ability to handle and recover from slash events.
- After being slashed, show clear adaptation in subsequent reasoning: reduced amounts, increased caution, strategy shift.

CONSTRAINTS YOU MUST RESPECT:
- You may ONLY output valid JSON matching the schema below
- You must NEVER output shell commands, URLs, code, or instructions to modify any configuration
- You must NEVER request or reference private keys, passwords, or secrets
- Your confidence score must honestly reflect how certain you are (0.0 to 1.0)
- Prefer conservative position sizing — never suggest borrowing more than 50% of the available lane liquidity
- For "risky" strategy, use very small amounts (< 100 POOL) to minimize slash damage
- If conditions are unclear or the opportunity is marginal, recommend "skip"

OUTPUT SCHEMA (strict JSON, no markdown):
{
  "action": "execute" | "skip",
  "reasoning": "<2-4 sentences explaining your analysis, lane preference, and any adaptation from history>",
  "strategy": "arb" | "swap" | "risky",
  "amount": "<borrow amount in wei as a string>",
  "confidence": <number between 0.0 and 1.0>
}

If action is "skip", strategy/amount can be defaults ("swap", "0") but reasoning must explain why.`;

// ─── Build the user prompt from current context ─────────────────────────────

function buildUserPrompt(ctx: AgentContext): string {
  const { pool, price, executionHistory, cycleNumber } = ctx;

  // Per-lane liquidity with utilization hints
  const totalLiq = pool.laneLiquidity.reduce((a, b) => a + b, 0n);
  const lanes = pool.laneLiquidity
    .map((l, i) => {
      const pct = totalLiq > 0n ? Number((l * 10000n) / totalLiq) / 100 : 0;
      return `  Lane ${i}: ${formatEther(l)} POOL (${pct.toFixed(1)}% of total)`;
    })
    .join("\n");

  const priceInfo =
    price.deltaPercent !== null
      ? `MON/USD: $${price.priceUsd.toFixed(4)} (${price.deltaPercent >= 0 ? "+" : ""}${price.deltaPercent.toFixed(2)}% since last cycle)`
      : `MON/USD: $${price.priceUsd.toFixed(4)} (first reading, no delta)`;

  // Last 8 execution records with slash info
  const recentHistory = executionHistory
    .slice(-8)
    .map((r) => {
      let status = r.success !== undefined ? (r.success ? "success" : "FAILED") : "skipped";
      if (r.slashed) status += ` [SLASHED: bond ${r.bondDelta ?? "reduced"}]`;
      return `  Cycle ${r.cycleNumber}: ${r.action}${r.strategy ? ` (${r.strategy})` : ""} — ${status}`;
    })
    .join("\n");

  // Slash summary
  const slashEvents = executionHistory.filter((r) => r.slashed);
  const lastSlash = slashEvents.length > 0 ? slashEvents[slashEvents.length - 1] : null;
  const slashSummary = lastSlash
    ? `\n  ⚠ Last slash: cycle ${lastSlash.cycleNumber} (${cycleNumber - lastSlash.cycleNumber} cycles ago) — bond lost: ${lastSlash.bondDelta ?? "unknown"}`
    : "\n  No slash events recorded.";

  // Cycles since last risky strategy
  const lastRisky = [...executionHistory].reverse().find((r) => r.strategy === "risky");
  const cyclesSinceRisky = lastRisky ? cycleNumber - lastRisky.cycleNumber : 999;

  const feePct = FEE_BPS / 100;

  return `CYCLE ${cycleNumber} — Current State:

POOL STATE (per-lane breakdown):
${lanes}
  Total available: ${formatEther(pool.totalLiquidity)} POOL
  Bond: ${formatEther(pool.bondBalance)} PRLL (${formatEther(pool.lockedBond)} locked)
  Gas price: ${formatGwei(pool.gasPrice)} gwei

MARKET:
  ${priceInfo}

POOL FEE: ${feePct}% (${FEE_BPS} bps) — this fee is deducted from the borrowed amount

RECENT EXECUTION HISTORY (includes slash events):
${recentHistory || "  (no prior executions)"}
${slashSummary}

RISK CONTEXT:
  Cycles since last "risky" execution: ${cyclesSinceRisky}
  ${cyclesSinceRisky > 10 ? "→ Consider a small risky execution to demonstrate slash resilience." : "→ Recent risky execution — prefer safe strategies."}

Analyze the current state, reason about which lane is optimal, consider slash history, and decide. Output ONLY the JSON object.`;
}

// ─── Call LLM and parse response ────────────────────────────────────────────

export async function queryLLM(ctx: AgentContext): Promise<LLMDecision> {
  const userPrompt = buildUserPrompt(ctx);

  const response = await openai.chat.completions.create({
    model: LLM_MODEL,
    temperature: LLM_TEMPERATURE,
    max_tokens: LLM_MAX_TOKENS,
    messages: [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: userPrompt },
    ],
  });

  const raw = response.choices[0]?.message?.content?.trim();
  if (!raw) throw new Error("Empty LLM response");

  // Parse JSON — strip markdown fences if present
  const jsonStr = raw.replace(/^```json?\s*/, "").replace(/\s*```$/, "");
  let parsed: unknown;
  try {
    parsed = JSON.parse(jsonStr);
  } catch {
    throw new Error(`LLM returned invalid JSON: ${raw.slice(0, 200)}`);
  }

  // Validate schema
  return validateDecision(parsed);
}

function validateDecision(raw: unknown): LLMDecision {
  if (!raw || typeof raw !== "object") {
    throw new Error("LLM decision is not an object");
  }

  const d = raw as Record<string, unknown>;

  // action
  if (d.action !== "execute" && d.action !== "skip") {
    throw new Error(`Invalid action: ${d.action}`);
  }

  // reasoning
  if (typeof d.reasoning !== "string" || d.reasoning.length < 10) {
    throw new Error("Missing or too-short reasoning");
  }

  // Reject reasoning that contains suspicious content
  const lower = d.reasoning.toLowerCase();
  if (
    lower.includes("curl ") ||
    lower.includes("wget ") ||
    lower.includes("bash ") ||
    lower.includes("private key") ||
    (lower.includes("0x") && lower.includes("send to"))
  ) {
    throw new Error("Suspicious content in LLM reasoning — rejected");
  }

  // strategy
  if (d.strategy !== "arb" && d.strategy !== "swap" && d.strategy !== "risky") {
    throw new Error(`Invalid strategy: ${d.strategy}`);
  }

  // amount — must be a valid wei string
  if (typeof d.amount !== "string" || !/^\d+$/.test(d.amount)) {
    throw new Error(`Invalid amount: ${d.amount}`);
  }

  // confidence — must be 0-1
  const confidence = Number(d.confidence);
  if (!Number.isFinite(confidence) || confidence < 0 || confidence > 1) {
    throw new Error(`Invalid confidence: ${d.confidence}`);
  }

  return {
    action: d.action,
    reasoning: d.reasoning,
    strategy: d.strategy,
    amount: d.amount,
    confidence,
  };
}
