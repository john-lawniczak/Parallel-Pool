import {
  createWalletClient,
  http,
  type Address,
  type WalletClient,
  type Hash,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { AGENT_PRIVATE_KEY, MONAD_RPC_URL, ADDRESSES, MODULE_ABI, monadTestnet } from "./config.js";
import { getPublicClient } from "./monitor.js";

// ─── Wallet client (singleton) ──────────────────────────────────────────────

let wallet: WalletClient;

export function getWalletClient(): WalletClient {
  if (!wallet) {
    const account = privateKeyToAccount(AGENT_PRIVATE_KEY);
    wallet = createWalletClient({
      account,
      chain: monadTestnet,
      transport: http(MONAD_RPC_URL),
    });
  }
  return wallet;
}

export function getAgentAddress(): Address {
  const account = privateKeyToAccount(AGENT_PRIVATE_KEY);
  return account.address;
}

// ─── Execute strategy ───────────────────────────────────────────────────────

/** Allowlisted module addresses — agent can ONLY call these */
const ALLOWED_MODULES: Record<string, Address> = {
  swap: ADDRESSES.swapModule as Address,
  arb: ADDRESSES.arbModule as Address,
  risky: ADDRESSES.badModule as Address, // MockBadModule — intentionally triggers slash
};

export interface ExecutionResult {
  txHash: Hash;
  gasUsed: bigint;
  success: boolean;
  error?: string;
}

export async function executeStrategy(
  strategy: "arb" | "swap" | "risky",
  amount: bigint
): Promise<ExecutionResult> {
  const moduleAddress = ALLOWED_MODULES[strategy];
  if (!moduleAddress) {
    return {
      txHash: "0x0" as Hash,
      gasUsed: 0n,
      success: false,
      error: `Unknown strategy: ${strategy}`,
    };
  }

  const w = getWalletClient();
  const pub = getPublicClient();
  const account = privateKeyToAccount(AGENT_PRIVATE_KEY);

  try {
    // Simulate first to catch reverts before spending gas
    await pub.simulateContract({
      address: moduleAddress,
      abi: MODULE_ABI,
      functionName: "execute",
      args: [amount],
      account: account,
    });

    // Send the real transaction
    const hash = await w.writeContract({
      address: moduleAddress,
      abi: MODULE_ABI,
      functionName: "execute",
      args: [amount],
      account: account,
      chain: monadTestnet,
    });

    // Wait for receipt
    const receipt = await pub.waitForTransactionReceipt({
      hash,
      timeout: 30_000,
    });

    return {
      txHash: hash,
      gasUsed: receipt.gasUsed,
      success: receipt.status === "success",
      error: receipt.status !== "success" ? "Transaction reverted" : undefined,
    };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return {
      txHash: "0x0" as Hash,
      gasUsed: 0n,
      success: false,
      error: msg.slice(0, 200),
    };
  }
}
