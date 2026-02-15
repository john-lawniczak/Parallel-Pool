import {
  createWalletClient,
  http,
  type Address,
  type WalletClient,
  zeroHash,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  AGENT_PRIVATE_KEY,
  MONITOR_PRIVATE_KEY,
  MONAD_RPC_URL,
  ADDRESSES,
  REPUTATION_REGISTRY_ABI,
  monadChain,
} from "./config.js";
import { getPublicClient } from "./monitor.js";
import { getWalletClient } from "./executor.js";
import type { AgentIdentity } from "./types.js";
import { logReputation, logError } from "./logger.js";

// ─── Monitor wallet (separate from agent — submits 3rd-party feedback) ──────

let monitorWallet: WalletClient | null = null;
let monitorAddress: string | null = null;

function getMonitorWallet(): WalletClient | null {
  if (monitorWallet) return monitorWallet;

  if (MONITOR_PRIVATE_KEY) {
    const monitorAccount = privateKeyToAccount(MONITOR_PRIVATE_KEY);
    monitorAddress = monitorAccount.address;
    monitorWallet = createWalletClient({
      account: monitorAccount,
      chain: monadChain,
      transport: http(MONAD_RPC_URL),
    });
    return monitorWallet;
  }

  return null;
}

export function getMonitorAddress(): string | null {
  if (monitorAddress) return monitorAddress;
  if (MONITOR_PRIVATE_KEY) {
    const monitorAccount = privateKeyToAccount(MONITOR_PRIVATE_KEY);
    monitorAddress = monitorAccount.address;
    return monitorAddress;
  }
  return null;
}

// ─── Submit reputation feedback after execution ─────────────────────────────
// Uses the monitor wallet (3rd-party) if available, otherwise falls back to agent wallet.
// ERC-8004 spec encourages feedback from independent observers for credibility.

export async function submitReputation(
  identity: AgentIdentity,
  success: boolean,
  strategy: "arb" | "swap" | "risky",
  slashed: boolean = false
): Promise<void> {
  if (!identity.registered || identity.agentId === null) {
    return; // Skip if no identity — graceful degradation
  }

  try {
    const monitor = getMonitorWallet();
    const pub = getPublicClient();

    // Determine which wallet submits feedback
    let feedbackWallet: WalletClient;
    let feedbackAccount: ReturnType<typeof privateKeyToAccount>;
    let submittedBy: string;

    if (monitor && MONITOR_PRIVATE_KEY) {
      // Preferred: independent monitor wallet submits feedback (3rd-party attestation)
      feedbackAccount = privateKeyToAccount(MONITOR_PRIVATE_KEY);
      feedbackWallet = monitor;
      submittedBy = "monitor";
    } else {
      // Fallback: reuse agent's singleton wallet (less credible but still recorded)
      feedbackAccount = privateKeyToAccount(AGENT_PRIVATE_KEY);
      feedbackWallet = getWalletClient();
      submittedBy = "self";
    }

    // Score: +100 for success, -50 for slash (worse than regular failure), 0 for regular failure
    const score = slashed ? -50n : success ? 100n : 0n;
    const tag1 = "flashAccess";
    const tag2 = slashed ? `${strategy}/slashed` : strategy;

    // Build a feedback URI with context
    const feedbackData = JSON.stringify({
      cycle: Date.now(),
      strategy,
      success,
      slashed,
      submittedBy,
    });
    const feedbackURI = `data:application/json;base64,${Buffer.from(feedbackData).toString("base64")}`;

    const hash = await feedbackWallet.writeContract({
      address: ADDRESSES.reputationRegistry as Address,
      abi: REPUTATION_REGISTRY_ABI,
      functionName: "giveFeedback",
      args: [
        identity.agentId,
        score, // int128 value
        0, // uint8 valueDecimals
        tag1, // tag1
        tag2, // tag2
        "", // endpoint (optional)
        feedbackURI, // feedbackURI — includes context
        zeroHash, // feedbackHash (optional)
      ],
      account: feedbackAccount,
      chain: monadChain,
    });

    await pub.waitForTransactionReceipt({ hash, timeout: 30_000 });

    logReputation(identity.agentId, Number(score), `${tag1}/${tag2}`);
  } catch (err) {
    // Reputation submission is non-critical — log and continue
    logError("reputation", err);
  }
}
