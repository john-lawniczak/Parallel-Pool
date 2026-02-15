# ParallelPool — Q&A

## Can the number of lanes ever grow too large? Are there DoS scenarios?

- **Lanes are fixed per deployment**: `numLanes` is immutable and constrained to \(1 \ldots 32\) at construction.
- **More lanes = more overhead**: deposit/withdraw/claimFees loop over all lanes, so extremely high `numLanes` would add gas overhead (the cap keeps this bounded).
- **DoS / contention model**:
  - **Per-lane flash access** can run concurrently across different lanes, but **same-lane** activity can serialize.
  - **Global operations** (`deposit`, `withdraw`, `claimFees`) are explicitly **not parallel-safe** and use a global lock; they will serialize with each other and can temporarily contend with flash access by consuming blockspace.
  - An attacker can't "brick all lanes" via same-lane contention; the worst-case is **degrading throughput** for protocols that hash into the same lane.

## Could protocols ever accidentally share the same lane? What is meant by "Callers assigned to the same lane may still serialize."

- **Yes, sharing a lane is expected**: lane assignment is deterministic and uses:
  - `laneId = uint256(uint160(protocol)) % numLanes`
- With more protocols than lanes, **collisions are inevitable**.
- **"Serialize"** means: two flash-access transactions that touch the **same lane vault** will contend on the same ERC-20 storage slot (`token.balanceOf[laneVault]`) and on the same per-lane lock, so Monad will not execute them in parallel.

## Could routing break?

- **Lane routing is deterministic** and computed from the protocol identity (`protocolLane(protocol)`).
- The callback is told exactly where to repay: `onFlashAccess(..., repayTo = address(laneVault), ...)`.
- If a callback repays the wrong address (or repays with a token quirk that reduces the vault balance), the invariant check (`balanceAfter >= balanceBefore`) fails and the transaction **reverts**. This makes "routing broke the pool" show up as a failed flash call, not silent state corruption.

## Expand on lane assignment being deterministic — how, exactly?

- Lane assignment is a pure function of the **protocol address** and the fixed `numLanes`:

  - `protocolLane(protocol) = uint160(protocol) % numLanes`

- This has two important properties:
  - **Order independence**: the lane chosen doesn't depend on mempool ordering, state, or block context.
  - **Delegated execution safety**: `flashAccessFor(protocol, ...)` uses the **protocol** (bonded identity) to pick the lane, not the executor.

## What about weird tokens and token types: different decimals, rebasing tokens, tokens with fees?

- **Different decimals**: decimals don't change contract math; amounts are always in the token's base units. (Decimals matter for UX, not safety.)
- **Fee-on-transfer / taxed tokens**:
  - Deposits use balance-delta accounting (so "received" reflects what actually arrived), but
  - Flash access requires the lane vault's balance to be restored to at least its pre-loan level. Fee-on-transfer on repayment can cause `balanceAfter < balanceBefore` and will **revert**.
- **Rebasing tokens**:
  - Rebases can change vault balances asynchronously and complicate accounting and invariants. The system is designed for standard ERC-20 behavior; rebasing assets are **not a target for MVP support**.
- **ERC777-style hooks / callback-y tokens**:
  - The design assumes adversarial callbacks; lane-level and global reentrancy guards limit reentrant surfaces, and `SafeERC20` is used for transfers.

## All the lanes are accessing the pool simultaneously — what if there's an issue with the pool? How is the pool reflecting this?

- **State separation is per lane vault, not per code path**:
  - Each lane vault is a separate contract holding liquidity, so lane-local balance changes do not require a shared pool token balance slot.
  - But all lanes still rely on the same pool logic for invariants/slashing/accountability; a logic bug would affect every lane.
- **Read-only visibility during callbacks**:
  - While a flash-access callback is executing, the lane vault temporarily holds fewer tokens (they're with the callback), so `laneLiquidity()` / `availableLiquidity()` will be **transiently deflated** mid-callback. External systems should not treat these views as oracles.
- **Failures are contained per call**:
  - If a callback fails to return principal, the flash call **reverts**.
  - If it returns principal but underpays fees, the call **succeeds** and slashes proportionally.
  - If a callback reverts, the whole transaction reverts, so temporary bond locks and transfers are rolled back.

## How does delegated execution work?

- A protocol can separate its **bonded identity** from the **executor** that submits transactions:
  - The protocol calls `authorizeExecutor(executor, true)`.
  - The protocol registers allowed callback contracts via `registerCallback(callback, true)` (or uses `callback == protocol`).
  - An authorized executor calls `flashAccessFor(protocol, amount, callback, data)`.
- The pool:
  - Checks bond/slashing against **`protocol`** (not executor),
  - Chooses the lane using **`protocol`**,
  - Enforces callback accountability using the protocol's registrations.

## How does the autonomous agent relate to ParallelPool?

The agent is a **pure off-chain consumer** of the deployed ParallelPool contracts — it reads on-chain state and submits transactions through the same `flashAccess` interface any protocol would use.

- The agent uses `viem` to read lane liquidity, bond balances, and gas prices from the Monad RPC
- It sends pool state + market signals to GPT-4o-mini, which returns a structured JSON decision (strategy, amount, confidence)
- The decision passes through 9 hard-coded safety checks the LLM cannot override
- If approved, the agent calls `module.execute(amount)` on an allowlisted strategy contract
- After execution, bond balance is re-read to detect slashing; the result feeds back into the LLM's context for the next cycle

This demonstrates how an autonomous agent can be built **on top of** a shared liquidity primitive — the agent doesn't need special access or contract modifications, just a bond and a registered callback.

Full architecture: [AGENT_ARCHITECTURE.md](./AGENT_ARCHITECTURE.md)

## How does the agent use ERC-8004?

The agent integrates both halves of the [ERC-8004 Trustless Agents Standard](https://eips.ethereum.org/EIPS/eip-8004):

- **Identity Registry** — at startup, the agent mints an ERC-721 NFT with a JSON agent card describing its capabilities, making it discoverable on 8004scan.io and agentscan.info
- **Reputation Registry** — after each execution, a **separate monitor wallet** (not the agent itself) submits `giveFeedback()` with a score (+100 success, 0 failure, -50 slashed) and contextual tags

The monitor wallet is a deliberate design choice: ERC-8004 reputation is more credible when attested by an independent observer rather than the agent rating itself. This aligns with ERC-8004's trust model where reputation builds through third-party attestation over time.

## Can they be front run? What stops a transaction from being MEV'd?

- **MEV is possible on Monad** — the mempool is public and validators can reorder transactions. FastLane (a decentralized MEV protocol) is live on Monad, confirming an active MEV ecosystem. However, several structural factors raise the bar significantly compared to typical AMM front-running:

- **Protocol-level protections in ParallelPool:**
  - **High barrier to front-run:** An attacker cannot simply copy a `flashAccess` call. They would need to deploy their own callback contract, register it, bond `minBond` worth of PRLL, and independently implement the same profitable strategy. This is far more costly than sandwiching an AMM swap.
  - **Deterministic lane assignment** — lane is a pure function of the protocol address, so transaction ordering cannot influence lane selection.
  - **Callback accountability** — only the protocol itself or pre-registered callbacks can receive borrowed tokens. Anonymous searchers cannot inject themselves into the flow.
  - **Bond + slashing** — every flash access requires collateral. Spam or fee-underpayment results in proportional slashing.

- **Monad-specific structural advantages:**
  - **400ms block times with ~800ms finality** — the MEV extraction window is ~30x shorter than Ethereum's 12-second slots. Searchers have far less time to observe, simulate, and front-run.
  - **Cheap gas reduces MEV profitability** — Monad's thesis is that low transaction costs enable frequent quote updates and tighter markets, structurally reducing the slippage and price impact that MEV feeds on.

- **Practical mitigations for protocol integrators:**
  - **FastLane integration** — Monad's native MEV infrastructure uses decentralized on-chain auctions rather than centralized relays. Protocols can participate in or defend against MEV through this mechanism.
  - **Strategy opacity** — keep strategy logic inside the callback contract rather than in calldata. On-chain bytecode is visible, but runtime state and off-chain inputs can make replication impractical.
  - **Private transaction submission** — where available, use private RPCs or builder endpoints to avoid mempool visibility entirely (recognizing this shifts trust to the relay operator).
