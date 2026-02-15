// ─── Shared Types ───────────────────────────────────────────────────────────

/** On-chain pool state snapshot */
export interface PoolState {
  laneLiquidity: bigint[]; // liquidity per lane (4 lanes)
  totalLiquidity: bigint;
  bondBalance: bigint; // caller's bond
  lockedBond: bigint; // caller's locked bond
  gasPrice: bigint; // current gas price in wei
  timestamp: number;
}

/** External price signal */
export interface PriceSignal {
  symbol: string; // e.g. "monad"
  priceUsd: number;
  previousPriceUsd: number | null;
  deltaPercent: number | null;
  timestamp: number;
}

/** Full state snapshot passed to LLM */
export interface AgentContext {
  pool: PoolState;
  price: PriceSignal;
  executionHistory: ExecutionRecord[];
  cycleNumber: number;
}

/** LLM decision output — structured JSON */
export interface LLMDecision {
  action: "execute" | "skip";
  reasoning: string;
  strategy: "arb" | "swap" | "risky";
  amount: string; // wei string
  confidence: number; // 0-1
}

/** Safety check result */
export interface SafetyResult {
  passed: boolean;
  checks: {
    name: string;
    passed: boolean;
    detail: string;
  }[];
  rejectionReason?: string;
}

/** Record of a single execution cycle */
export interface ExecutionRecord {
  cycleNumber: number;
  timestamp: number;
  action: "execute" | "skip" | "rejected";
  strategy?: "arb" | "swap" | "risky";
  amount?: string;
  txHash?: string;
  gasUsed?: bigint;
  success?: boolean;
  slashed?: boolean; // true if bond decreased after execution
  bondDelta?: string; // bond change in wei (negative = slashed)
  reasoning: string;
  error?: string;
}

/** ERC-8004 agent identity state */
export interface AgentIdentity {
  agentId: bigint | null;
  registered: boolean;
  walletAddress: string;
}

/** Safety configuration caps */
export interface SafetyCaps {
  maxBorrowPerCycle: bigint;
  maxBorrowDaily: bigint;
  minBondFloor: bigint;
  maxGasPriceWei: bigint;
  minConfidence: number;
  circuitBreakerThreshold: number; // consecutive failures before halt
}
