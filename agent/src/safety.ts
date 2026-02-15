import { parseEther } from "viem";
import { SAFETY } from "./config.js";
import type { LLMDecision, PoolState, SafetyResult } from "./types.js";

/** Hard cap for "risky" strategy — BadModule causes slashing, limit exposure */
const RISKY_MAX = parseEther("100"); // 100 POOL

// ─── Mutable daily tracking (resets at midnight UTC) ────────────────────────

let dailyBorrowed = 0n;
let dailyResetDate = todayUTC();

function todayUTC(): string {
  return new Date().toISOString().slice(0, 10);
}

function maybeResetDaily(): void {
  const today = todayUTC();
  if (today !== dailyResetDate) {
    dailyBorrowed = 0n;
    dailyResetDate = today;
  }
}

export function getDailyBorrowed(): bigint {
  maybeResetDaily();
  return dailyBorrowed;
}

export function recordBorrow(amount: bigint): void {
  maybeResetDaily();
  dailyBorrowed += amount;
}

// ─── Consecutive failure tracking ───────────────────────────────────────────

let consecutiveFailures = 0;

export function recordSuccess(): void {
  consecutiveFailures = 0;
}

export function recordFailure(): void {
  consecutiveFailures++;
}

export function getConsecutiveFailures(): number {
  return consecutiveFailures;
}

export function isCircuitBroken(): boolean {
  return consecutiveFailures >= SAFETY.circuitBreakerThreshold;
}

// ─── Validate an LLM decision against hard safety caps ──────────────────────

export function validateDecision(
  decision: LLMDecision,
  pool: PoolState
): SafetyResult {
  maybeResetDaily();

  const amount = BigInt(decision.amount);
  const checks: SafetyResult["checks"] = [];

  // 1. Max borrow per cycle
  const borrowOk = amount <= SAFETY.maxBorrowPerCycle;
  checks.push({
    name: "maxBorrowPerCycle",
    passed: borrowOk,
    detail: `${formatCompact(amount)}/${formatCompact(SAFETY.maxBorrowPerCycle)}`,
  });

  // 2. Daily limit
  const dailyOk = dailyBorrowed + amount <= SAFETY.maxBorrowDaily;
  checks.push({
    name: "dailyLimit",
    passed: dailyOk,
    detail: `daily=${formatCompact(dailyBorrowed + amount)}/${formatCompact(SAFETY.maxBorrowDaily)}`,
  });

  // 3. Bond floor
  const bondOk = pool.bondBalance >= SAFETY.minBondFloor;
  checks.push({
    name: "bondFloor",
    passed: bondOk,
    detail: `bond=${formatCompact(pool.bondBalance)} >= ${formatCompact(SAFETY.minBondFloor)}`,
  });

  // 4. Gas ceiling
  const gasOk = pool.gasPrice <= SAFETY.maxGasPriceWei;
  checks.push({
    name: "gasPrice",
    passed: gasOk,
    detail: `gas=${formatGweiCompact(pool.gasPrice)} <= ${formatGweiCompact(SAFETY.maxGasPriceWei)}`,
  });

  // 5. Confidence threshold
  const confOk = decision.confidence >= SAFETY.minConfidence;
  checks.push({
    name: "confidence",
    passed: confOk,
    detail: `conf=${decision.confidence.toFixed(2)} >= ${SAFETY.minConfidence}`,
  });

  // 6. Lane liquidity — don't borrow more than 80% of any lane
  const maxLane = pool.laneLiquidity.reduce(
    (max, l) => (l > max ? l : max),
    0n
  );
  const laneOk = amount <= (maxLane * 80n) / 100n;
  checks.push({
    name: "laneLiquidity",
    passed: laneOk,
    detail: `amount <= 80% of max lane (${formatCompact(maxLane)})`,
  });

  // 7. Amount is positive
  const positiveOk = amount > 0n;
  checks.push({
    name: "positiveAmount",
    passed: positiveOk,
    detail: amount > 0n ? "amount > 0" : "amount is zero",
  });

  // 8. Risky strategy cap — BadModule causes slashing, limit exposure
  const riskyOk = decision.strategy !== "risky" || amount <= RISKY_MAX;
  checks.push({
    name: "riskyStrategyCap",
    passed: riskyOk,
    detail:
      decision.strategy === "risky"
        ? `risky amount ${formatCompact(amount)} <= ${formatCompact(RISKY_MAX)}`
        : "non-risky strategy (no cap)",
  });

  // 9. Circuit breaker
  const cbOk = !isCircuitBroken();
  checks.push({
    name: "circuitBreaker",
    passed: cbOk,
    detail: `failures=${consecutiveFailures}/${SAFETY.circuitBreakerThreshold}`,
  });

  const allPassed = checks.every((c) => c.passed);
  const firstFailure = checks.find((c) => !c.passed);

  return {
    passed: allPassed,
    checks,
    rejectionReason: firstFailure
      ? `${firstFailure.name}: ${firstFailure.detail}`
      : undefined,
  };
}

// ─── Formatting helpers ─────────────────────────────────────────────────────

function formatCompact(wei: bigint): string {
  const eth = Number(wei) / 1e18;
  return eth.toLocaleString("en-US", { maximumFractionDigits: 1 });
}

function formatGweiCompact(wei: bigint): string {
  return (Number(wei) / 1e9).toFixed(0) + "gwei";
}
