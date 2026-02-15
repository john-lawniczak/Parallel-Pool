import { formatEther, formatGwei } from "viem";
import type {
  AgentContext,
  AgentIdentity,
  ExecutionRecord,
  LLMDecision,
  SafetyResult,
} from "./types.js";

// ─── ANSI Colors ────────────────────────────────────────────────────────────

const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const RED = "\x1b[31m";
const CYAN = "\x1b[36m";
const MAGENTA = "\x1b[35m";
const WHITE = "\x1b[37m";

// ─── Helpers ────────────────────────────────────────────────────────────────

function ts(): string {
  return new Date().toISOString().replace("T", " ").slice(0, 19);
}

function fmtEth(wei: bigint): string {
  const num = Number(formatEther(wei));
  return num.toLocaleString("en-US", { maximumFractionDigits: 2 });
}

function line(char: string, len: number): string {
  return char.repeat(len);
}

// ─── Public API ─────────────────────────────────────────────────────────────

export function logBanner(identity: AgentIdentity): void {
  const w = 60;
  console.log();
  console.log(`${BOLD}${CYAN}${line("=", w)}${RESET}`);
  console.log(
    `${BOLD}${CYAN}  ParallelPool Liquidity Agent v1.0${RESET}`
  );
  if (identity.registered && identity.agentId !== null) {
    console.log(
      `${CYAN}  ERC-8004 Agent ID: #${identity.agentId} (registered on Monad)${RESET}`
    );
  } else {
    console.log(`${YELLOW}  ERC-8004: not yet registered${RESET}`);
  }
  console.log(
    `${CYAN}  Wallet: ${identity.walletAddress.slice(0, 6)}...${identity.walletAddress.slice(-4)}${RESET}`
  );
  console.log(`${BOLD}${CYAN}${line("=", w)}${RESET}`);
  console.log();
}

export function logCycleStart(cycleNumber: number): void {
  console.log(
    `${DIM}[${ts()}]${RESET} ${BOLD}${WHITE}=== CYCLE ${cycleNumber} ===${RESET}`
  );
}

export function logPoolState(ctx: AgentContext): void {
  const { pool, price } = ctx;
  console.log(`${CYAN}  Pool State:${RESET}`);
  for (let i = 0; i < pool.laneLiquidity.length; i++) {
    const liq = fmtEth(pool.laneLiquidity[i]);
    process.stdout.write(
      `    Lane ${i}: ${BOLD}${liq} POOL${RESET}${i < pool.laneLiquidity.length - 1 ? " | " : "\n"}`
    );
  }
  console.log(
    `    Bond: ${BOLD}${fmtEth(pool.bondBalance)} PRLL${RESET} (${fmtEth(pool.lockedBond)} locked) | Gas: ${formatGwei(pool.gasPrice)} gwei`
  );

  // Price signal
  console.log(`${CYAN}  Price Signal:${RESET}`);
  if (price.deltaPercent !== null && price.previousPriceUsd !== null) {
    const arrow = price.deltaPercent >= 0 ? "+" : "";
    console.log(
      `    MON/USD: $${price.previousPriceUsd.toFixed(4)} -> $${price.priceUsd.toFixed(4)} (${arrow}${price.deltaPercent.toFixed(2)}%)`
    );
  } else {
    console.log(`    MON/USD: $${price.priceUsd.toFixed(4)} (first reading)`);
  }
}

export function logLLMDecision(decision: LLMDecision): void {
  const icon = decision.action === "execute" ? `${GREEN}>>` : `${YELLOW}--`;
  console.log();
  console.log(`${MAGENTA}  LLM Reasoning:${RESET}`);

  // Wrap reasoning text at ~70 chars
  const words = decision.reasoning.split(" ");
  let buf = "    ";
  for (const w of words) {
    if (buf.length + w.length > 74) {
      console.log(`${DIM}${buf}${RESET}`);
      buf = "    ";
    }
    buf += w + " ";
  }
  if (buf.trim()) console.log(`${DIM}${buf}${RESET}`);

  console.log();
  console.log(
    `${icon} Decision: ${BOLD}${decision.action.toUpperCase()}${RESET} | strategy=${decision.strategy} | amount=${fmtEth(BigInt(decision.amount))} POOL | confidence=${decision.confidence.toFixed(2)}${RESET}`
  );
}

export function logSafetyResult(result: SafetyResult): void {
  if (result.passed) {
    const details = result.checks
      .map((c) => `${c.passed ? GREEN + "+" : RED + "x"}${RESET} ${c.detail}`)
      .join(" | ");
    console.log(`  ${GREEN}Safety: PASS${RESET} [${details}]`);
  } else {
    console.log(`  ${RED}Safety: BLOCKED — ${result.rejectionReason}${RESET}`);
    for (const c of result.checks.filter((ch) => !ch.passed)) {
      console.log(`    ${RED}x ${c.name}: ${c.detail}${RESET}`);
    }
  }
}

export function logExecution(record: ExecutionRecord): void {
  if (record.slashed) {
    console.log(
      `  ${RED}SLASHED:${RESET} tx ${record.txHash?.slice(0, 10)}...${record.txHash?.slice(-6)} | strategy: ${record.strategy} | bond delta: ${record.bondDelta}`
    );
  } else if (record.success) {
    console.log(
      `  ${GREEN}EXECUTED:${RESET} tx ${record.txHash?.slice(0, 10)}...${record.txHash?.slice(-6)} | gas: ${record.gasUsed?.toLocaleString()} | strategy: ${record.strategy}`
    );
  } else {
    console.log(
      `  ${RED}FAILED:${RESET} ${record.error ?? "unknown error"}`
    );
  }
}

export function logSlash(
  slashAmount: bigint,
  bondBefore: bigint,
  bondAfter: bigint,
  strategy: string
): void {
  console.log();
  console.log(
    `  ${RED}${BOLD}⚠ SLASHED!${RESET}${RED} Strategy "${strategy}" triggered bond slash${RESET}`
  );
  console.log(
    `  ${RED}  Bond: ${fmtEth(bondBefore)} → ${fmtEth(bondAfter)} PRLL (lost ${fmtEth(slashAmount)} PRLL)${RESET}`
  );
  console.log(
    `  ${YELLOW}  Agent will adapt strategy in next cycles...${RESET}`
  );
  console.log();
}

export function logReputation(agentId: bigint, score: number, tag: string): void {
  console.log(
    `  ${MAGENTA}Reputation:${RESET} agentId=#${agentId} | score=${score} | tag=${tag}`
  );
}

export function logMemorySummary(
  history: ExecutionRecord[],
  dailyBorrowed: bigint,
  dailyLimit: bigint
): void {
  const executed = history.filter((r) => r.action === "execute");
  const successes = executed.filter((r) => r.success);
  const slashes = executed.filter((r) => r.slashed);
  const rate =
    executed.length > 0
      ? ((successes.length / executed.length) * 100).toFixed(0)
      : "N/A";
  const slashInfo = slashes.length > 0 ? ` | ${RED}slashes: ${slashes.length}${RESET}${DIM}` : "";
  console.log(
    `  ${DIM}Memory: ${successes.length}/${executed.length} successful (${rate}%)${slashInfo} | daily: ${fmtEth(dailyBorrowed)}/${fmtEth(dailyLimit)} POOL${RESET}`
  );
  console.log();
}

export function logSkip(reason: string): void {
  console.log(`  ${YELLOW}SKIPPED: ${reason}${RESET}`);
  console.log();
}

export function logCircuitBreaker(consecutiveFailures: number): void {
  console.log(
    `\n  ${RED}${BOLD}CIRCUIT BREAKER TRIGGERED${RESET}${RED} — ${consecutiveFailures} consecutive failures. Agent halting.${RESET}\n`
  );
}

export function logError(context: string, err: unknown): void {
  const msg = err instanceof Error ? err.message : String(err);
  console.log(`  ${RED}ERROR (${context}): ${msg}${RESET}`);
}
