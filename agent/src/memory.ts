import type { ExecutionRecord } from "./types.js";

// ─── In-memory execution history ────────────────────────────────────────────

const MAX_HISTORY = 50; // keep last 50 records
const history: ExecutionRecord[] = [];

export function addRecord(record: ExecutionRecord): void {
  history.push(record);
  if (history.length > MAX_HISTORY) {
    history.shift();
  }
}

export function getHistory(): ExecutionRecord[] {
  return [...history]; // defensive copy
}

export function getRecentHistory(n: number = 10): ExecutionRecord[] {
  return history.slice(-n);
}

/** Count executed (not skipped) records */
export function getExecutionStats(): {
  total: number;
  executed: number;
  successes: number;
  failures: number;
  skipped: number;
} {
  const executed = history.filter((r) => r.action === "execute");
  const successes = executed.filter((r) => r.success === true);
  const failures = executed.filter((r) => r.success === false);
  const skipped = history.filter((r) => r.action === "skip" || r.action === "rejected");

  return {
    total: history.length,
    executed: executed.length,
    successes: successes.length,
    failures: failures.length,
    skipped: skipped.length,
  };
}
