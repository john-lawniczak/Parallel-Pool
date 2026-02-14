# Monad Testnet Deployment — On-Chain Proof (Post-Audit-Fix)

**Chain:** Monad Testnet (chain ID 10143)  
**Deployer:** `0xf11e7F83B59aD1dF23EfF9Bf4A5E2b4b3ab756Aa`  
**Date:** 2026-02-14  
**Total Gas:** 1.035 MON (10,045,617 gas × avg 103 gwei)  
**Block Range:** 12841359 – 12841482  

> **Status:** Fresh deployment after applying all audit fixes (BondRegistry balance-delta accounting). All 3 demo scenarios executed successfully on-chain. All 8 contracts verified (exact match) on Sourcify/MonadVision.

---

## Deployed Contracts

| Contract | Address | Deploy Tx | Block |
|---|---|---|---|
| Pool Token (POOL) | `0x1BE0E7FF9b692C05549d53c90fCA059823797216` | `0xe177b10d9e0799bb83408254f49e74cfa31a4745b6f254f6ce9ffed00b0d7788` | 12841359 |
| PRLL Token | `0x65b69850CCddAd0247E529101A4f2B3394c4790d` | `0x6b0c2bf3bc874a211f167dd0ec2406123aa1fe7fc6ea522f311f737d6d4aa75b` | 12841365 |
| BondRegistry | `0x0CB51160f40c7ec20583FD68ed86A07e534DBeF4` | `0x171137fbe47e32845c2daf4b5749cfca76146c54aa7b7bd40766503309692ceb` | 12841370 |
| **ParallelPool** | **`0x4908eCb26738f1e2912680D001d37d735790944e`** | `0x8e137337514febcd1ba9a189b76b21074db8dd4954659fb1aef4fbf26db18281` | 12841375 |
| MockSwapModule | `0xD99359E7fAcB9C10DE188c92fc7D6b1d3BbCbe8E` | `0x749a2707bb827a9ee88823feed9f7838b41d81080261c8f7b17c11f05fc19eb1` | 12841385 |
| MockArbModule | `0x3c322a224bd2c4ef90652a70e36447a301944A37` | `0x60867f522c9e36c1916d78296dc3a73c615193be12ec1c15b51711450de69b9c` | 12841389 |
| MockBadModule | `0xeFD6733b7f9453359f75c8ad7cC5518282e667cf` | `0xc8ff4cb1c74c3971a7aa4c5ebd2675e0fedd24b4e8702bc38fd51f09bfdc79d4` | 12841394 |

**ParallelPool config:** 4 lanes, 10 bps fee, 1000 PRLL min bond, fee receiver = deployer  
**BondRegistry slash receiver:** `0x000000000000000000000000000000000000dEaD` (canonical burn address — slashed PRLL is irrecoverable)

---

## Lane Vaults (created by ParallelPool constructor)

| Lane | Vault Address |
|---|---|
| 0 | `0xb1A4Ce485A42Ee332DF259EEbAE9a9c94BC2d57B` |
| 1 | `0x5B8D699bD84aD22541786BeC8251b33887eADEe7` |
| 2 | `0xC781017D9186117D52227143D019610bc54D78C6` |
| 3 | `0x52cecDDE9A67c4565770d9603071aF07A21A59B4` |

---

## Demo Transactions (on-chain proof of all core features)

### Setup (txs 1–19)
- Deploy contracts, authorize pool, register callbacks, seed 10,000 POOL liquidity (2,500 per lane), bond 1,000 PRLL
- Authorize pool in registry: `0x4e7135d8ce5e1d5e9174c940061f4c4461596fb2c3e5690c403ea6f80bb11619` (block 12841380)
- Deposit 10,000 POOL: `0xc7dd0aa22cc83f92a2f833e9362b5ee7c0fd829ed680a44cc802597cf4ae3c1a` (block 12841408)
- Bond 1,000 PRLL: `0xa03bbe1e3f314fc8627c513b632c9ce877b400e5d67b93d7f215b2590a5f31c0` (block 12841425)

### Demo 1 — Happy Path: SwapModule (1,000 POOL flash access)
| Step | Tx Hash | Block |
|---|---|---|
| `flashAccess(1000 POOL, SwapModule)` | `0x73bbba6324671d4840a0c03e1da2b4710eee6743e793cc5a9ac6faaa2f29d5f8` | 12841455 |
| `claimFees()` | `0xb2e84c8114afe7ab8fa222fed98ab9e2fc55b1788f24e5fb0b27e1fac2c2ccc6` | 12841461 |

- **Result:** Module repaid 1,001 POOL (principal + 1 POOL fee). Fee accrued in vault, then claimed to deployer. Bond intact at 1,000 PRLL.
- **Events:** `FlashAccess(fee=1e18, feePaid=1e18)`, `FeesAccrued(laneId=2, amount=1e18)`, `FeesClaimed(receiver=deployer, totalAmount=1e18)`

### Demo 2 — Happy Path: ArbModule (500 POOL flash access)
| Step | Tx Hash | Block |
|---|---|---|
| `flashAccess(500 POOL, ArbModule)` | `0xd560700f5282ff6dd2a9a56f005371dcfdaf8457cbd3ab9d884b2013aca9a4de` | 12841466 |
| `claimFees()` | `0x62f82a74924f2744695e467611c83a4c649e5233896e006a5224d483a79b51f1` | 12841472 |

- **Result:** Module repaid 500.5 POOL (principal + 0.5 POOL fee). Fee accrued in vault, then claimed. Bond intact at 1,000 PRLL.
- **Events:** `FlashAccess(fee=5e17, feePaid=5e17)`, `FeesAccrued(laneId=2, amount=5e17)`, `FeesClaimed(receiver=deployer, totalAmount=5e17)`

### Demo 3 — Proportional Slash: BadModule (500 POOL flash access, no fee paid)
| Step | Tx Hash | Block |
|---|---|---|
| `flashAccess(500 POOL, BadModule)` | `0xf522943d17f7efdbba443f050ab6fd9783ff1924670e3edba9b899e17538345f` | 12841477 |
| `claimFees()` (no-op) | `0xfb03a00de7ca5ae6efd14a8b8b65e12734ae447ecad4d0d12d5d53aa4a3a8fdc` | 12841482 |

- **Result:** Module returned only 500 POOL (missing 0.5 POOL fee). **0.5 PRLL slashed proportionally** from bond. Bond reduced from 1,000 → 999.5 PRLL. Slashed PRLL sent to `0x000000000000000000000000000000000000dEaD`.
- **Events:** `Slashed(feeShortfall=5e17, slashAmount=5e17)`, `FlashAccess(fee=5e17, feePaid=0)`
- **Slashing evidence:** 0.5 PRLL transferred to `BURN_ADDRESS` in tx `0xf522943d...` — visible as a `Transfer(BondRegistry → 0x...dEaD, 5e17)` event.

---

## Key Observations

1. **Parallel-native architecture proven:** 4 independent LaneVaults deployed on-chain, each holding separate liquidity. Protocols are deterministically assigned to lanes to avoid hot-slot contention.
2. **Pull-based fee routing works:** Fees correctly accrued in LaneVaults via `FeesAccrued` events; claimed by `feeReceiver` (deployer) via `claimFees()`. Both fee claim txs confirmed on-chain.
3. **Proportional slashing works:** BadModule's fee shortfall (0.5 POOL) resulted in exactly 0.5 PRLL slashed — not the full bond. Slashed tokens sent to burn address (`0x...dEaD`).
4. **Callback accountability works:** Modules registered as callbacks via `registerCallback()`. Only authorized callbacks accepted.
5. **Balance-delta accounting (audit fix) deployed:** BondRegistry.bond() now uses `balanceOf(before/after)` to credit only actual received tokens, preventing fee-on-transfer inflation.
6. **All invariants held:** Pool remained solvent across all 3 flash accesses. Lane liquidity preserved.

---

## Verification

All 8 contracts verified via **Sourcify** (exact match) on MonadVision explorer.

| Contract | Address | Sourcify Status | Explorer Link |
|---|---|---|---|
| Pool Token (POOL) | `0x1BE0E7FF...97216` | exact_match | [MonadVision](https://testnet.monadexplorer.com/address/0x1BE0E7FF9b692C05549d53c90fCA059823797216) |
| PRLL Token | `0x65b69850...4790d` | exact_match | [MonadVision](https://testnet.monadexplorer.com/address/0x65b69850CCddAd0247E529101A4f2B3394c4790d) |
| BondRegistry | `0x0CB51160...DBeF4` | exact_match | [MonadVision](https://testnet.monadexplorer.com/address/0x0CB51160f40c7ec20583FD68ed86A07e534DBeF4) |
| ParallelPool | `0x4908eCb2...0944e` | exact_match | [MonadVision](https://testnet.monadexplorer.com/address/0x4908eCb26738f1e2912680D001d37d735790944e) |
| LaneVault (lane 0) | `0xb1A4Ce48...2d57B` | exact_match | [MonadVision](https://testnet.monadexplorer.com/address/0xb1A4Ce485A42Ee332DF259EEbAE9a9c94BC2d57B) |
| MockSwapModule | `0xD99359E7...be8E` | exact_match | [MonadVision](https://testnet.monadexplorer.com/address/0xD99359E7fAcB9C10DE188c92fc7D6b1d3BbCbe8E) |
| MockArbModule | `0x3c322a22...4A37` | exact_match | [MonadVision](https://testnet.monadexplorer.com/address/0x3c322a224bd2c4ef90652a70e36447a301944A37) |
| MockBadModule | `0xeFD6733b...67cf` | exact_match | [MonadVision](https://testnet.monadexplorer.com/address/0xeFD6733b7f9453359f75c8ad7cC5518282e667cf) |

Verified with:
```bash
forge verify-contract <ADDRESS> <CONTRACT> \
  --chain 10143 --verifier sourcify \
  --verifier-url https://sourcify-api-monad.blockvision.org/ \
  --constructor-args $(cast abi-encode "constructor(...)" ...)
```

---

## Reproduction

```bash
source .env && forge script script/Demo.s.sol:DemoScript \
  --rpc-url https://testnet-rpc.monad.xyz \
  --account monad-deployer \
  --sender 0xf11e7f83b59ad1df23eff9bf4a5e2b4b3ab756aa \
  --broadcast -vvvv
```

Full broadcast artifact: `broadcast/Demo.s.sol/10143/run-latest.json`
