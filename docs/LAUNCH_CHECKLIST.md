# ParallelPool — Launch / Submission Checklist

Use this as a **single preflight** before recording + testnet run + submission.

---

## 0) Scope lock (do not ship surprises)
- [x] No last-minute features beyond P0/P1 in `TODO.md`
- [x] Docs match code (no claims you can't prove on-chain)

---

## 1) Core invariants (must be true)
- [x] **Principal shortfall**: if pool balance after callback < before → **tx reverts** (pool cannot lose principal)
- [x] **Fee shortfall**: if principal returned but fee underpaid → **tx does not revert** and **slashing persists**
- [x] **Accountability**: the slashed identity is unambiguous (protocol vs executor is explicitly defined)
- [x] **Parallel story**: lanes/vaults are shipped; demo and docs state **parallelism is per-lane**

---

## 2) Token + bond utility (judge sanity check)
- [x] "Why bond?" is concrete: **required for access** (not governance, not vibes)
- [x] "Why slash?" is concrete: underpayment is penalized **without revert**, so griefing costs real money
- [x] Slashing amount is **rational** (proportional to fee shortfall or clearly justified)
- [x] Slashed funds destination is explicit (burn via `0x...dEaD`) and shown in events

---

## 3) LP economics (no obvious brokenness)
- [x] Fees are **explicitly routed** to a receiver (LP fee-sharing labeled **v2**)
- [x] LP principal accounting is consistent (no "fees trapped in pool") — pull-based `claimFees()`, balance-delta accounting

---

## 4) Security preflight (MVP-grade)
- [x] `SafeERC20` used for token transfers/transferFrom
- [x] Reentrancy guarded on flash path — 3-layer: per-lane lock, global lock, `_flashActive` counter
- [x] Callback surface is bounded (either `callback == msg.sender` or registered callback per protocol)
- [x] Admin/owner powers are documented (and minimized for MVP)
- [x] Assumptions documented (standard ERC20; fee-on-transfer handled via balance-delta accounting)

---

## 5) Tests (artifact > claims)
Run locally and ensure these exist and pass: **116 tests passing (unit, fuzz 1M+ calls, invariant, integration)**
- [x] **Order independence**: AB vs BA same end state for non-conflicting accesses (per-lane) — `Integration.t.sol`
- [x] **Principal shortfall**: reverts and **no slashing persists**
- [x] **Fee shortfall**: succeeds and **slashing persists**
- [x] **Reentrancy attempt**: blocked — `SecurityFindings.t.sol`
- [x] Edge cases: fee rounding, zero/low amounts, fee-on-transfer tokens — `AuditFixes.t.sol`

---

## 6) Events + observability (demo must be provable)
- [x] Events include enough data to prove outcome: `FlashAccess(amount, fee, feePaid)`, `Slashed(feeShortfall, slashAmount)`, `FeesAccrued`, `FeesClaimed`
- [x] Read-only views exist for demo introspection: `bondOf()`, `availableLiquidity()`, `laneLiquidity()`
- [x] Demo output prints: pre-state → tx hash → post-state deltas — `Demo.s.sol`

---

## 7) Testnet deployment (Monad) evidence
- [x] Deploy script is deterministic and repeatable
- [x] Record and save:
  - [x] deployed addresses — `docs/DEPLOYMENT.md`
  - [x] deployment tx hashes — blocks 12841359–12841482
  - [x] block numbers
- [x] Contracts are verified (Sourcify exact match, all 8 contracts)
- [x] Demo txs executed on testnet and saved:
  - [x] two successful accesses (SwapModule + ArbModule)
  - [x] fee-shortfall slash tx (non-reverting) — BadModule, 0.5 PRLL burned
  - [ ] principal-shortfall revert tx — *not demonstrated on testnet*

> **Note:** Current testnet deployment is pre-`noFlashActive` guard fix. Needs fresh deploy to match latest code.

---

## 8) 3-minute judge demo (final rehearsal)
- [ ] Opening line: "Parallel EVM parallelizes **non-conflicting state**; we design to avoid hot-slot conflicts."
- [ ] Show **on-chain proof** (events + balances + bond changes), not narration
- [ ] Show the asymmetric rule:
  - [ ] principal shortfall → revert
  - [ ] fee shortfall → slash without revert
- [ ] Close with one sentence differentiation:
  - [ ] Not ERC-4626 (not yield vault)
  - [ ] Not just flash loans (bonded access + non-reverting slashing + parallel-native conflict design)

> **Status:** Demo video not yet recorded (P0.4 in `TODO.md`). Talking points and script ready in `docs/DEMO_SCRIPT.md`.

---

## 9) Submission assets
- [x] README: crisp "what/why/how", 30-second skim-friendly
- [x] `docs/ARCHITECTURE.md` updated to match final design (esp. lanes/conflict model)
- [x] `docs/DEMO_SCRIPT.md` matches actual commands and expected output
- [x] One-pager / pitch deck updated — `docs/PITCH_DECK_ONE_PAGER.md`
- [ ] A single "Proof" section with:
  - [x] testnet addresses — in `docs/DEPLOYMENT.md`
  - [x] demo tx hashes — in `docs/DEPLOYMENT.md`
  - [ ] short clip / recording link (if required) — *demo video not yet recorded*

> **Remaining:** Mainnet deployment (P0.1), nad.fun token (P0.2), public repo push (P0.3), demo video (P0.4), tweet (P0.5), submission form (P0.6). See `TODO.md` for full details.
