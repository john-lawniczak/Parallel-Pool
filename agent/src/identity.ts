import { type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  AGENT_PRIVATE_KEY,
  ADDRESSES,
  IDENTITY_REGISTRY_ABI,
  monadChain,
} from "./config.js";
import { getPublicClient } from "./monitor.js";
import { getWalletClient } from "./executor.js";
import type { AgentIdentity } from "./types.js";

// ─── Agent card (public metadata) ───────────────────────────────────────────

const AGENT_CARD = {
  type: "https://eips.ethereum.org/EIPS/eip-8004#registration-v1",
  name: "ParallelPool Liquidity Agent",
  description:
    "Autonomous AI agent that manages flash access strategies across ParallelPool's parallel lanes on Monad. Uses GPT-4o-mini for real-time market analysis and decision-making. Bonded with PRLL, builds verifiable reputation from execution outcomes.",
  image: "",
  services: [
    {
      name: "web",
      endpoint: "https://github.com/JohnLaw/Parallel-Pool",
    },
  ],
  active: true,
  supportedTrust: ["reputation"],
};

// ─── Encode agent card as a data URI ────────────────────────────────────────

function agentCardDataURI(): string {
  const json = JSON.stringify(AGENT_CARD);
  const base64 = Buffer.from(json).toString("base64");
  return `data:application/json;base64,${base64}`;
}

// ─── Register or recover existing identity ──────────────────────────────────

export async function ensureIdentity(): Promise<AgentIdentity> {
  const account = privateKeyToAccount(AGENT_PRIVATE_KEY);
  const walletAddress = account.address;
  const pub = getPublicClient();
  const registryAddress = ADDRESSES.identityRegistry as Address;

  // Check if already registered (has an NFT in the registry)
  try {
    const balance = (await pub.readContract({
      address: registryAddress,
      abi: IDENTITY_REGISTRY_ABI,
      functionName: "balanceOf",
      args: [walletAddress],
    })) as bigint;

    if (balance > 0n) {
      // Already registered — get our agent ID
      const agentId = (await pub.readContract({
        address: registryAddress,
        abi: IDENTITY_REGISTRY_ABI,
        functionName: "tokenOfOwnerByIndex",
        args: [walletAddress, 0n],
      })) as bigint;

      return { agentId, registered: true, walletAddress };
    }
  } catch {
    // Registry might not exist on testnet — continue to registration attempt
  }

  // Register new identity
  try {
    const uri = agentCardDataURI();
    const w = getWalletClient();

    const hash = await w.writeContract({
      address: registryAddress,
      abi: IDENTITY_REGISTRY_ABI,
      functionName: "register",
      args: [uri],
      account,
      chain: monadChain,
    });

    const receipt = await pub.waitForTransactionReceipt({
      hash,
      timeout: 30_000,
    });

    if (receipt.status !== "success") {
      console.log(
        "  ERC-8004 registration tx reverted — continuing without identity"
      );
      return { agentId: null, registered: false, walletAddress };
    }

    // Try to extract agentId from logs (Transfer event from ERC-721 mint)
    // The tokenId is typically in the third topic of the Transfer event
    let agentId: bigint | null = null;
    for (const log of receipt.logs) {
      if (log.topics.length >= 4) {
        // Transfer(address,address,uint256) — topic[3] is tokenId
        agentId = BigInt(log.topics[3]!);
        break;
      }
    }

    return { agentId, registered: true, walletAddress };
  } catch {
    // ERC-8004 might not be on testnet — degrade gracefully
    console.log(
      "  ERC-8004 registry not available on this network — continuing without identity"
    );
    return { agentId: null, registered: false, walletAddress };
  }
}
