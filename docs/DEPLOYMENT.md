# Monad Mainnet Deployment — On-Chain Proof

**Chain:** Monad Mainnet (chain ID 143)  
**Deployer:** `0xf11e7F83B59aD1dF23EfF9Bf4A5E2b4b3ab756Aa`  
**Date:** 2026-02-15  
**Block Range:** 55577901 – 55579309  
**Tooling:** [Monad Foundry](https://docs.monad.xyz/tooling-and-infra/toolkits/monad-foundry) v1.5.0-stable-monad

> **Status:** Full deployment + all 3 demo scenarios (swap, arb, proportional slash) executed successfully on Monad Mainnet. Monad Foundry required for accurate gas estimation — Monad charges based on `gas_limit` with no gas refunds and uses different opcode pricing than Ethereum.

---

## Deployed Contracts

| Contract | Address | Deploy Tx | Block |
|---|---|---|---|
| Pool Token (POOL) | [`0x0c6ADF5E204C0Cf5B5c97442464d4c25a5155b4F`](https://monadexplorer.com/address/0x0c6ADF5E204C0Cf5B5c97442464d4c25a5155b4F) | [`0xa69b121d...`](https://monadexplorer.com/tx/0xa69b121db1d6434ae28b7ce6617e57bda13ccba1e979a18ee1b7bf1f0d551ea8) | 55577901 |
| PRLL Token | [`0x0d31FF18ff8B26F3861737bFd83Bd4617AA1e3F5`](https://monadexplorer.com/address/0x0d31FF18ff8B26F3861737bFd83Bd4617AA1e3F5) | [`0x720c30bc...`](https://monadexplorer.com/tx/0x720c30bcee344966b01057e61d5750027a71f371d703a15d5c9f7fa1c29bbde8) | 55577907 |
| BondRegistry | [`0xD11ce2204499367f58d12E0f2364Ac0b4c8f79C8`](https://monadexplorer.com/address/0xD11ce2204499367f58d12E0f2364Ac0b4c8f79C8) | [`0xad77c7e6...`](https://monadexplorer.com/tx/0xad77c7e639e59e5f895f4c7cf0530f1efcf44da07fece4d38dd22ecef0507d34) | 55577913 |
| **ParallelPool** | [**`0xa9bb3620c2335e30DC8e6dAd55440400EDd7a366`**](https://monadexplorer.com/address/0xa9bb3620c2335e30DC8e6dAd55440400EDd7a366) | [`0x6ac9d21a...`](https://monadexplorer.com/tx/0x6ac9d21ab3dcd3e54c603fee2f685be3ca6634537dc33e718809b1af05bc2125) | 55577918 |
| MockSwapModule | [`0xE18911EB24450Bc5319598A885a85d7B16EC6bdE`](https://monadexplorer.com/address/0xE18911EB24450Bc5319598A885a85d7B16EC6bdE) | [`0xd8850e87...`](https://monadexplorer.com/tx/0xd8850e87e55ea1de40a32d8d796a8185155b3ac98f76b3d0860be63fb750f37f) | 55577930 |
| MockArbModule | [`0xA7ddE29B5Abd8DB7F6663CCA82C2812728f5E04a`](https://monadexplorer.com/address/0xA7ddE29B5Abd8DB7F6663CCA82C2812728f5E04a) | [`0xfdb3b275...`](https://monadexplorer.com/tx/0xfdb3b275d07a5d1e6f776ab1556a74f8be9a6564baa529d143e7e7e2fa806b92) | 55577935 |
| MockBadModule | [`0x8Afb2Fd8cADD2a51DA81cCCa84c15113E632CB6a`](https://monadexplorer.com/address/0x8Afb2Fd8cADD2a51DA81cCCa84c15113E632CB6a) | [`0xb124390e...`](https://monadexplorer.com/tx/0xb124390e6a28fb11f4291c20a5d29e21eccb82172dcac7bb0034df0c0457e475) | 55577940 |

**ParallelPool config:** 4 lanes, 10 bps fee, 1000 PRLL min bond, fee receiver = deployer
**BondRegistry slash receiver:** `0x000000000000000000000000000000000000dEaD` (canonical burn address — slashed PRLL is irrecoverable)

---

## Lane Vaults (created by ParallelPool constructor)

| Lane | Vault Address |
|---|---|
| 0 | [`0xde9c6bd9e121c3d52Ec0f55484b66480E0099f7E`](https://monadexplorer.com/address/0xde9c6bd9e121c3d52Ec0f55484b66480E0099f7E) |
| 1 | [`0x6eC4e2A8bEf50e33311ae7e4aeef3de20A1F8B67`](https://monadexplorer.com/address/0x6eC4e2A8bEf50e33311ae7e4aeef3de20A1F8B67) |
| 2 | [`0xc3c7B031670Bf92af4482f49641846E72BD11499`](https://monadexplorer.com/address/0xc3c7B031670Bf92af4482f49641846E72BD11499) |
| 3 | [`0x0137681927610814FbDAFD87cDa585D51Adeb898`](https://monadexplorer.com/address/0x0137681927610814FbDAFD87cDa585D51Adeb898) |

---

## Setup Transactions

| Step | Tx Hash | Block |
|---|---|---|
| Authorize pool in registry | [`0xfc942c99...`](https://monadexplorer.com/tx/0xfc942c99a5191c8d5e7b458dc9c08bb6b0aae43da8115d937f5737d9a8e3dadf) | 55577925 |
| Mint 10,000 POOL to deployer | [`0x96cd9117...`](https://monadexplorer.com/tx/0x96cd911725ae1579fca06be809f4d30ccd0ca995207e530c546d85a67d934d10) | 55577944 |
| Approve POOL for ParallelPool | [`0x4a74acef...`](https://monadexplorer.com/tx/0x4a74acefb80bfbd1316b840503a34ea5f0e35e6eff533b08d301c8f07a6a319a) | 55577949 |
| Deposit 10,000 POOL (2,500 per lane) | [`0xfa993929...`](https://monadexplorer.com/tx/0xfa99392907715e0d434880c7aaa86ea6c2a435005b6afd30410fdfe7c8ded862) | 55578730 |
| Mint 1,000 PRLL to deployer | [`0x6986e9af...`](https://monadexplorer.com/tx/0x6986e9afca966105a5002e7d6568fd4dfff39649f8491c43904ebd63cf7a3e19) | 55578737 |
| Approve PRLL for BondRegistry | [`0xda604bad...`](https://monadexplorer.com/tx/0xda604bad0fdc9b12a168e4908774c0990421aaabe3881742f3f5b2782b3dd998) | 55578742 |
| Bond 1,000 PRLL | [`0x4fb6b8b1...`](https://monadexplorer.com/tx/0x4fb6b8b12876dc051c31833894cb7bd61e32004c20d605ae3c6c81ce4581d3f6) | 55578747 |
| Register SwapModule callback | [`0x57cae274...`](https://monadexplorer.com/tx/0x57cae274d4b9cece4726d44010e0856fe8415bb5d7780f1244ae596befda91fe) | 55578751 |
| Register ArbModule callback | [`0x61112a5b...`](https://monadexplorer.com/tx/0x61112a5b2d5d88ecc5d132a86318900b8298abe21f588ef7633a3552afbe4a81) | 55578756 |
| Register BadModule callback | [`0x0e3c8a3c...`](https://monadexplorer.com/tx/0x0e3c8a3cc66ef09e38465cd44f73181bdae7034d332879a77b90e8dd65c17e08) | 55578760 |
| Mint 100 POOL to SwapModule | [`0xc861c907...`](https://monadexplorer.com/tx/0xc861c90794edf85ded13c7eb65ee0b5178bc8215dd0aacb6ecdb02104c868c80) | 55578766 |
| Mint 100 POOL to ArbModule | [`0xcdf6d6a8...`](https://monadexplorer.com/tx/0xcdf6d6a8ed9f2121703ac1fb7dec7777ac1b39e5c43af2f55042ada201606169) | 55578770 |

---

## Demo Transactions (on-chain proof of all core features)

### Demo 1 — Happy Path: SwapModule (1,000 POOL flash access)

| Step | Tx Hash | Block |
|---|---|---|
| `flashAccess(1000 POOL, SwapModule)` | [`0x0799bcf1...`](https://monadexplorer.com/tx/0x0799bcf1ec04439fc759e0f5a7fe78362fe8fbc06df975f8253650bd54ba87f7) | 55578774 |
| `claimFees()` | [`0xad318846...`](https://monadexplorer.com/tx/0xad318846e8828ed773992072d65af28086f1465ea1b7ac4412cc16cdae4396a8) | 55579286 |

- **Result:** Module repaid 1,001 POOL (principal + 1 POOL fee). Fee accrued in lane vault, then claimed to deployer. Bond intact at 1,000 PRLL.
- **Events:** `FlashAccess(fee=1e18, feePaid=1e18)`, `FeesAccrued(laneId=2, amount=1e18)`, `FeesClaimed(receiver=deployer, totalAmount=1e18)`

### Demo 2 — Happy Path: ArbModule (500 POOL flash access)

| Step | Tx Hash | Block |
|---|---|---|
| `flashAccess(500 POOL, ArbModule)` | [`0x5093aa40...`](https://monadexplorer.com/tx/0x5093aa40e4bedbd9ed5b1ef36eb8f584136941f57af7d19702e5f127ee1ad40a) | 55579293 |
| `claimFees()` | [`0xb32a788f...`](https://monadexplorer.com/tx/0xb32a788f03f405b693f6aa41c22aa980572fd01fa179df2adbc8c1629562d4b2) | 55579298 |

- **Result:** Module repaid 500.5 POOL (principal + 0.5 POOL fee). Fee accrued in lane vault, then claimed. Bond intact at 1,000 PRLL.
- **Events:** `FlashAccess(fee=5e17, feePaid=5e17)`, `FeesAccrued(laneId=2, amount=5e17)`, `FeesClaimed(receiver=deployer, totalAmount=5e17)`

### Demo 3 — Proportional Slash: BadModule (500 POOL flash access, no fee paid)

| Step | Tx Hash | Block |
|---|---|---|
| `flashAccess(500 POOL, BadModule)` | [`0x374b7d3d...`](https://monadexplorer.com/tx/0x374b7d3d529130b5bd081d2be9c2c105340e3a379b37bd3a4b180622d6ea1056) | 55579303 |
| `claimFees()` (no-op) | [`0x7e6c2dcc...`](https://monadexplorer.com/tx/0x7e6c2dcc500dcce10e1863629f7f6287053886b49d459c4091c504fbf383510a) | 55579309 |

- **Result:** Module returned only 500 POOL (missing 0.5 POOL fee). **0.5 PRLL slashed proportionally** from bond. Bond reduced from 1,000 to 999.5 PRLL. Slashed PRLL sent to `0x000000000000000000000000000000000000dEaD`.
- **Events:** `Slashed(feeShortfall=5e17, slashAmount=5e17)`, `FlashAccess(fee=5e17, feePaid=0)`
- **Slashing evidence:** 0.5 PRLL transferred to `BURN_ADDRESS` — visible as a `Transfer(BondRegistry -> 0x...dEaD, 5e17)` event.

---

## Final On-Chain State

```
Lane 0: 2,500 POOL (25.0%)    | accrued fees: 0
Lane 1: 2,500 POOL (25.0%)    | accrued fees: 0
Lane 2: 2,500 POOL (25.0%)    | accrued fees: 0 (claimed)
Lane 3: 2,500 POOL (25.0%)    | accrued fees: 0
Total liquidity: 10,000 POOL
Fee receiver balance: 1.5 POOL (1.0 + 0.5 from Demos 1 & 2)
Bond: 999.5 PRLL (0.5 PRLL slashed in Demo 3)
```

---

## Key Observations

1. **Parallel-native architecture proven:** 4 independent LaneVaults deployed on-chain, each holding separate liquidity. Protocols are deterministically assigned to lanes to avoid hot-slot contention.
2. **Pull-based fee routing works:** Fees correctly accrued in LaneVaults via `FeesAccrued` events; claimed by `feeReceiver` (deployer) via `claimFees()`. All fee claim txs confirmed on-chain.
3. **Proportional slashing works:** BadModule's fee shortfall (0.5 POOL) resulted in exactly 0.5 PRLL slashed — not the full bond. Slashed tokens sent to burn address (`0x...dEaD`).
4. **Callback accountability works:** Modules registered as callbacks via `registerCallback()`. Only authorized callbacks accepted.
5. **Balance-delta accounting deployed:** BondRegistry.bond() uses `balanceOf(before/after)` to credit only actual received tokens, preventing fee-on-transfer inflation.
6. **All invariants held:** Pool remained solvent across all 3 flash accesses. Lane liquidity preserved.

---

## Monad Foundry Requirement

Monad Foundry is **required** for deploying and running scripts on Monad. Standard Foundry underestimates gas because:
- **Gas charging:** Monad charges based on `gas_limit`, not `gas_used` — there are no gas refunds
- **Opcode pricing:** Monad uses different gas costs for storage operations and precompiles

Install:
```bash
curl -L https://raw.githubusercontent.com/category-labs/foundry/monad/foundryup/install | bash
foundryup --network monad
```

See [Monad Foundry documentation](https://docs.monad.xyz/tooling-and-infra/toolkits/monad-foundry) for details.

---

## Reproduction

```bash
# Install Monad Foundry first (see above)

source .env && forge script script/Demo.s.sol:DemoScript \
  --rpc-url https://rpc.monad.xyz \
  --account monad-deployer \
  --sender 0xf11e7f83b59ad1df23eff9bf4a5e2b4b3ab756aa \
  --broadcast --slow -vvvv
```

Full broadcast artifacts: `broadcast/Demo.s.sol/143/run-latest.json`

---

## Historical: Monad Testnet Deployment

A prior deployment was done on Monad Testnet (chain ID 10143) during development. The testnet deployment is no longer the canonical reference — all on-chain proof is on Monad Mainnet above.
