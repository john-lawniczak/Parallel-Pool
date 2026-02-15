import "dotenv/config";
import { parseEther, parseGwei, type Abi } from "viem";
import type { SafetyCaps } from "./types.js";

// ─── Environment ────────────────────────────────────────────────────────────

function requireEnv(key: string): string {
  const val = process.env[key];
  if (!val) throw new Error(`Missing required env var: ${key}`);
  return val;
}

export const OPENAI_API_KEY = requireEnv("OPENAI_API_KEY");
export const MONAD_RPC_URL = process.env.MONAD_RPC_URL ?? "https://testnet-rpc.monad.xyz";
export const AGENT_PRIVATE_KEY = requireEnv("AGENT_PRIVATE_KEY") as `0x${string}`;
// Separate monitor wallet for ERC-8004 reputation (spec requires feedback NOT from agent owner)
function parseOptionalPrivateKey(key: string | undefined): `0x${string}` | undefined {
  if (!key) return undefined;
  if (!/^0x[0-9a-fA-F]{64}$/.test(key)) {
    console.warn(`  WARN: MONITOR_PRIVATE_KEY is set but has invalid format — ignoring`);
    return undefined;
  }
  return key as `0x${string}`;
}
export const MONITOR_PRIVATE_KEY = parseOptionalPrivateKey(process.env.MONITOR_PRIVATE_KEY);

// ─── Chain Definition (single source of truth) ──────────────────────────────

export const monadTestnet = {
  id: 10143,
  name: "Monad Testnet",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: {
    default: { http: [MONAD_RPC_URL] },
  },
} as const;

// ─── Timing ─────────────────────────────────────────────────────────────────

export const CYCLE_INTERVAL_MS = Number(process.env.CYCLE_INTERVAL_MS ?? "15000");

// ─── Deployed Contract Addresses (Monad Testnet) ────────────────────────────

export const ADDRESSES = {
  poolToken: "0x1BE0E7FF9b692C05549d53c90fCA059823797216" as const,
  prllToken: "0x65b69850CCddAd0247E529101A4f2B3394c4790d" as const,
  bondRegistry: "0x0CB51160f40c7ec20583FD68ed86A07e534DBeF4" as const,
  parallelPool: "0x4908eCb26738f1e2912680D001d37d735790944e" as const,
  swapModule: "0xD99359E7fAcB9C10DE188c92fc7D6b1d3BbCbe8E" as const,
  arbModule: "0x3c322a224bd2c4ef90652a70e36447a301944A37" as const,
  badModule: "0xeFD6733b7f9453359f75c8ad7cC5518282e667cf" as const, // MockBadModule — triggers slash
  // ERC-8004 registries (Monad mainnet — also available on testnet)
  identityRegistry: "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432" as const,
  reputationRegistry: "0x8004BAa17C55a88189AE136b182e5fdA19dE9b63" as const,
} as const;

export const NUM_LANES = 4;
export const FEE_BPS = 10; // 0.1%

// ─── Safety Caps (hard-coded — LLM cannot override) ─────────────────────────

export const SAFETY: SafetyCaps = {
  maxBorrowPerCycle: parseEther(process.env.MAX_BORROW_PER_CYCLE ?? "1000"),
  maxBorrowDaily: parseEther("5000"),
  minBondFloor: parseEther("500"),
  maxGasPriceWei: parseGwei(process.env.MAX_GAS_PRICE_GWEI ?? "500"),
  minConfidence: 0.6,
  circuitBreakerThreshold: 3,
};

// ─── LLM Config ─────────────────────────────────────────────────────────────

export const LLM_MODEL = "gpt-4o-mini";
export const LLM_MAX_TOKENS = 512;
export const LLM_TEMPERATURE = 0.3; // low temp for consistent structured output

// ─── ABIs (minimal — only the functions we call/read) ───────────────────────

export const PARALLEL_POOL_ABI = [
  {
    type: "function",
    name: "laneLiquidity",
    inputs: [{ name: "laneId", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "availableLiquidity",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "numLanes",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "protocolLane",
    inputs: [{ name: "protocol", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "accruedFees",
    inputs: [{ name: "laneId", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
] as const satisfies Abi;

export const BOND_REGISTRY_ABI = [
  {
    type: "function",
    name: "bondOf",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "lockedBondOf",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
] as const satisfies Abi;

export const MODULE_ABI = [
  {
    type: "function",
    name: "execute",
    inputs: [{ name: "amount", type: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const satisfies Abi;

// ERC-8004 Identity Registry — minimal ABI
export const IDENTITY_REGISTRY_ABI = [
  {
    type: "function",
    name: "register",
    inputs: [{ name: "agentURI", type: "string" }],
    outputs: [{ name: "agentId", type: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "tokenOfOwnerByIndex",
    inputs: [
      { name: "owner", type: "address" },
      { name: "index", type: "uint256" },
    ],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
] as const satisfies Abi;

// ERC-8004 Reputation Registry — minimal ABI
export const REPUTATION_REGISTRY_ABI = [
  {
    type: "function",
    name: "giveFeedback",
    inputs: [
      { name: "agentId", type: "uint256" },
      { name: "value", type: "int128" },
      { name: "valueDecimals", type: "uint8" },
      { name: "tag1", type: "string" },
      { name: "tag2", type: "string" },
      { name: "endpoint", type: "string" },
      { name: "feedbackURI", type: "string" },
      { name: "feedbackHash", type: "bytes32" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const satisfies Abi;
