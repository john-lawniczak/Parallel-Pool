import { CYCLE_INTERVAL_MS, SAFETY } from "./config.js";
import { readPoolState, readPriceSignal, readBondBalance } from "./monitor.js";
import { queryLLM } from "./llm.js";
import {
  validateDecision,
  recordBorrow,
  recordSuccess,
  recordFailure,
  isCircuitBroken,
  getConsecutiveFailures,
  getDailyBorrowed,
} from "./safety.js";
import { executeStrategy, getAgentAddress } from "./executor.js";
import { ensureIdentity } from "./identity.js";
import { submitReputation, getMonitorAddress } from "./reputation.js";
import { addRecord, getRecentHistory } from "./memory.js";
import {
  logBanner,
  logCycleStart,
  logPoolState,
  logLLMDecision,
  logSafetyResult,
  logExecution,
  logSlash,
  logMemorySummary,
  logSkip,
  logCircuitBreaker,
  logError,
} from "./logger.js";
import type { AgentContext, AgentIdentity, ExecutionRecord } from "./types.js";

// ─── Main ───────────────────────────────────────────────────────────────────

let running = true;
let cycleNumber = 0;

async function main(): Promise<void> {
  console.log("\n  Starting ParallelPool Liquidity Agent...\n");

  // ── Step 1: Register ERC-8004 identity ──
  let identity: AgentIdentity;
  try {
    console.log("  Registering ERC-8004 identity...");
    identity = await ensureIdentity();
  } catch (err) {
    // Degrade gracefully — run without identity
    logError("startup-identity", err);
    identity = {
      agentId: null,
      registered: false,
      walletAddress: getAgentAddress(),
    };
  }

  const monAddr = getMonitorAddress();
  if (monAddr) {
    console.log(`  Monitor wallet: ${monAddr.slice(0, 6)}...${monAddr.slice(-4)} (3rd-party reputation)`);
  }

  logBanner(identity);

  // ── Step 2: Main loop ──
  while (running) {
    cycleNumber++;

    try {
      await runCycle(identity);
    } catch (err) {
      logError(`cycle-${cycleNumber}`, err);
      recordFailure();
    }

    // Check circuit breaker
    if (isCircuitBroken()) {
      logCircuitBreaker(getConsecutiveFailures());
      break;
    }

    // Wait for next cycle
    await sleep(CYCLE_INTERVAL_MS);
  }

  console.log("\n  Agent stopped.\n");
}

// ─── Single Cycle ───────────────────────────────────────────────────────────

async function runCycle(identity: AgentIdentity): Promise<void> {
  logCycleStart(cycleNumber);

  // 1. Monitor — read on-chain state + price
  const callerAddress = getAgentAddress();
  const [pool, price] = await Promise.all([
    readPoolState(callerAddress),
    readPriceSignal(),
  ]);

  const ctx: AgentContext = {
    pool,
    price,
    executionHistory: getRecentHistory(10),
    cycleNumber,
  };

  logPoolState(ctx);

  // 2. LLM — get decision
  const decision = await queryLLM(ctx);
  logLLMDecision(decision);

  // 3. If skip, log and return
  if (decision.action === "skip") {
    const record: ExecutionRecord = {
      cycleNumber,
      timestamp: Date.now(),
      action: "skip",
      reasoning: decision.reasoning,
    };
    addRecord(record);
    logSkip(decision.reasoning.slice(0, 100));
    logMemorySummary(getRecentHistory(20), getDailyBorrowed(), SAFETY.maxBorrowDaily);
    return;
  }

  // 4. Safety — validate decision
  const safetyResult = validateDecision(decision, pool);
  logSafetyResult(safetyResult);

  if (!safetyResult.passed) {
    const record: ExecutionRecord = {
      cycleNumber,
      timestamp: Date.now(),
      action: "rejected",
      strategy: decision.strategy,
      amount: decision.amount,
      reasoning: `Safety rejected: ${safetyResult.rejectionReason}`,
    };
    addRecord(record);
    logMemorySummary(getRecentHistory(20), getDailyBorrowed(), SAFETY.maxBorrowDaily);
    return;
  }

  // 5. Fresh-read bond BEFORE execution (don't use stale pool.bondBalance —
  //    the LLM call may have taken seconds since the initial pool read)
  let bondBefore = pool.bondBalance;
  try {
    bondBefore = await readBondBalance(callerAddress);
  } catch {
    // Fall back to the pool snapshot if fresh read fails
  }

  // 6. Execute on-chain
  const amount = BigInt(decision.amount);
  const result = await executeStrategy(decision.strategy, amount);

  // 7. Read bond AFTER execution (detect slashing)
  let slashed = false;
  let bondDelta = "0";
  try {
    const bondAfter = await readBondBalance(callerAddress);
    if (bondAfter < bondBefore) {
      slashed = true;
      const loss = bondBefore - bondAfter;
      bondDelta = `-${loss.toString()}`;
      logSlash(loss, bondBefore, bondAfter, decision.strategy);
    }
  } catch (err) {
    logError("slash-detection", err);
  }

  const record: ExecutionRecord = {
    cycleNumber,
    timestamp: Date.now(),
    action: "execute",
    strategy: decision.strategy,
    amount: decision.amount,
    txHash: result.txHash,
    gasUsed: result.gasUsed,
    success: result.success && !slashed,
    slashed,
    bondDelta: slashed ? bondDelta : undefined,
    reasoning: decision.reasoning,
    error: result.error,
  };

  addRecord(record);
  logExecution(record);

  if (result.success && !slashed) {
    recordBorrow(amount);
    recordSuccess();
  } else {
    recordFailure();
  }

  // 8. Submit reputation via monitor wallet (non-blocking)
  submitReputation(identity, result.success && !slashed, decision.strategy, slashed).catch(
    (err) => logError("reputation-async", err)
  );

  // 9. Summary
  logMemorySummary(getRecentHistory(20), getDailyBorrowed(), SAFETY.maxBorrowDaily);
}

// ─── Utilities ──────────────────────────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ─── Graceful shutdown ──────────────────────────────────────────────────────

process.on("SIGINT", () => {
  console.log("\n  Received SIGINT — shutting down gracefully...");
  running = false;
});

process.on("SIGTERM", () => {
  console.log("\n  Received SIGTERM — shutting down gracefully...");
  running = false;
});

// ─── Run ────────────────────────────────────────────────────────────────────

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
