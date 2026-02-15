import {
  createPublicClient,
  http,
  type PublicClient,
  type Address,
} from "viem";
import {
  MONAD_RPC_URL,
  ADDRESSES,
  PARALLEL_POOL_ABI,
  BOND_REGISTRY_ABI,
  monadTestnet,
} from "./config.js";
import type { PoolState, PriceSignal } from "./types.js";

// ─── Viem public client (read-only) ────────────────────────────────────────

let client: PublicClient;

export function getPublicClient(): PublicClient {
  if (!client) {
    client = createPublicClient({
      chain: monadTestnet,
      transport: http(MONAD_RPC_URL),
    });
  }
  return client;
}

// ─── On-chain state ─────────────────────────────────────────────────────────

export async function readPoolState(callerAddress: Address): Promise<PoolState> {
  const pub = getPublicClient();
  const poolAddr = ADDRESSES.parallelPool as Address;
  const bondAddr = ADDRESSES.bondRegistry as Address;

  // Read all state in parallel (individual calls — Monad testnet has no multicall3)
  const [lane0, lane1, lane2, lane3, totalLiq, bondBal, lockedBond, gasPrice] =
    await Promise.all([
      pub.readContract({ address: poolAddr, abi: PARALLEL_POOL_ABI, functionName: "laneLiquidity", args: [0n] }).catch(() => 0n) as Promise<bigint>,
      pub.readContract({ address: poolAddr, abi: PARALLEL_POOL_ABI, functionName: "laneLiquidity", args: [1n] }).catch(() => 0n) as Promise<bigint>,
      pub.readContract({ address: poolAddr, abi: PARALLEL_POOL_ABI, functionName: "laneLiquidity", args: [2n] }).catch(() => 0n) as Promise<bigint>,
      pub.readContract({ address: poolAddr, abi: PARALLEL_POOL_ABI, functionName: "laneLiquidity", args: [3n] }).catch(() => 0n) as Promise<bigint>,
      pub.readContract({ address: poolAddr, abi: PARALLEL_POOL_ABI, functionName: "availableLiquidity" }).catch(() => 0n) as Promise<bigint>,
      pub.readContract({ address: bondAddr, abi: BOND_REGISTRY_ABI, functionName: "bondOf", args: [callerAddress] }).catch(() => 0n) as Promise<bigint>,
      pub.readContract({ address: bondAddr, abi: BOND_REGISTRY_ABI, functionName: "lockedBondOf", args: [callerAddress] }).catch(() => 0n) as Promise<bigint>,
      pub.getGasPrice(),
    ]);

  return {
    laneLiquidity: [lane0, lane1, lane2, lane3],
    totalLiquidity: totalLiq,
    bondBalance: bondBal,
    lockedBond: lockedBond,
    gasPrice,
    timestamp: Date.now(),
  };
}

// ─── Standalone bond reader (for pre/post slash detection) ───────────────────

export async function readBondBalance(callerAddress: Address): Promise<bigint> {
  const pub = getPublicClient();
  const bondAddr = ADDRESSES.bondRegistry as Address;
  return (await pub.readContract({
    address: bondAddr,
    abi: BOND_REGISTRY_ABI,
    functionName: "bondOf",
    args: [callerAddress],
  })) as bigint;
}

// ─── Price feed (CoinGecko free API — no key needed) ────────────────────────

const COINGECKO_URL =
  "https://api.coingecko.com/api/v3/simple/price?ids=monad&vs_currencies=usd";

// Input validation limits to prevent prompt injection via absurd data
const PRICE_MIN = 0.0001;
const PRICE_MAX = 100_000;

let lastPrice: number | null = null;

export async function readPriceSignal(): Promise<PriceSignal> {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);

    const res = await fetch(COINGECKO_URL, { signal: controller.signal });
    clearTimeout(timeout);

    if (!res.ok) throw new Error(`CoinGecko HTTP ${res.status}`);

    const data = await res.json();

    // Validate response structure
    if (
      !data ||
      typeof data !== "object" ||
      !data.monad ||
      typeof data.monad.usd !== "number"
    ) {
      throw new Error("Invalid CoinGecko response structure");
    }

    const price = data.monad.usd as number;

    // Range validation — reject absurd values
    if (price < PRICE_MIN || price > PRICE_MAX || !Number.isFinite(price)) {
      throw new Error(`Price out of valid range: ${price}`);
    }

    const previousPriceUsd = lastPrice;
    const deltaPercent =
      previousPriceUsd !== null
        ? ((price - previousPriceUsd) / previousPriceUsd) * 100
        : null;

    lastPrice = price;

    return {
      symbol: "monad",
      priceUsd: price,
      previousPriceUsd,
      deltaPercent,
      timestamp: Date.now(),
    };
  } catch (err) {
    // On failure, return last known price with no delta (safe default)
    return {
      symbol: "monad",
      priceUsd: lastPrice ?? 0,
      previousPriceUsd: lastPrice,
      deltaPercent: null,
      timestamp: Date.now(),
    };
  }
}
