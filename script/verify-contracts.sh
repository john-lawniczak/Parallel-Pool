#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [ ! -f ".env" ]; then
  echo "Missing .env. Create it from .env.example and set MONAD_EXPLORER_KEY."
  exit 1
fi

# shellcheck disable=SC1091
source ".env"

# ══════════════════════════════════════════════════════════════════════════════
# Contract Addresses (from Monad Mainnet deployment)
# ══════════════════════════════════════════════════════════════════════════════

POOL_TOKEN="0x0c6ADF5E204C0Cf5B5c97442464d4c25a5155b4F"
PRLL_TOKEN="0x0d31FF18ff8B26F3861737bFd83Bd4617AA1e3F5"
BOND_REGISTRY="0xD11ce2204499367f58d12E0f2364Ac0b4c8f79C8"
PARALLEL_POOL="0xa9bb3620c2335e30DC8e6dAd55440400EDd7a366"
MOCK_SWAP_MODULE="0xE18911EB24450Bc5319598A885a85d7B16EC6bdE"
MOCK_ARB_MODULE="0xA7ddE29B5Abd8DB7F6663CCA82C2812728f5E04a"
MOCK_BAD_MODULE="0x8Afb2Fd8cADD2a51DA81cCCa84c15113E632CB6a"

# Lane Vaults (created by ParallelPool constructor)
LANE_VAULT_0="0xde9c6bd9e121c3d52Ec0f55484b66480E0099f7E"
LANE_VAULT_1="0x6eC4e2A8bEf50e33311ae7e4aeef3de20A1F8B67"
LANE_VAULT_2="0xc3c7B031670Bf92af4482f49641846E72BD11499"
LANE_VAULT_3="0x0137681927610814FbDAFD87cDa585D51Adeb898"

DEPLOYER="0xf11e7F83B59aD1dF23EfF9Bf4A5E2b4b3ab756Aa"

# ══════════════════════════════════════════════════════════════════════════════
# Verification Functions
# ══════════════════════════════════════════════════════════════════════════════

verify_monadscan() {
  local address=$1
  local contract=$2
  local args=${3:-}
  
  echo "  → Monadscan (Etherscan API v2): $contract at $address"
  
  if [ -z "${ETHERSCAN_API_KEY:-}" ]; then
    echo "    ⚠ ETHERSCAN_API_KEY not set, skipping Monadscan"
    return 0
  fi
  
  if [ -n "$args" ]; then
    forge verify-contract "$address" "$contract" \
      --chain 143 \
      --verifier etherscan \
      --etherscan-api-key "$ETHERSCAN_API_KEY" \
      --verifier-url "https://api.etherscan.io/v2/api?chainid=143" \
      --constructor-args "$args" \
      || echo "    ⚠ Verification may have failed or contract already verified"
  else
    forge verify-contract "$address" "$contract" \
      --chain 143 \
      --verifier etherscan \
      --etherscan-api-key "$ETHERSCAN_API_KEY" \
      --verifier-url "https://api.etherscan.io/v2/api?chainid=143" \
      || echo "    ⚠ Verification may have failed or contract already verified"
  fi
}

verify_socialscan() {
  local address=$1
  local contract=$2
  local args=${3:-}
  
  echo "  → SocialScan: $contract at $address"
  
  if [ -n "$args" ]; then
    forge verify-contract "$address" "$contract" \
      --chain 143 \
      --verifier etherscan \
      --verifier-url "https://api.socialscan.io/monad-mainnet/v1/explorer/command_api/contract" \
      --constructor-args "$args" \
      || echo "    ⚠ Verification may have failed or contract already verified"
  else
    forge verify-contract "$address" "$contract" \
      --chain 143 \
      --verifier etherscan \
      --verifier-url "https://api.socialscan.io/monad-mainnet/v1/explorer/command_api/contract" \
      || echo "    ⚠ Verification may have failed or contract already verified"
  fi
}

verify_both() {
  local address=$1
  local contract=$2
  local args=${3:-}
  
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "Verifying: $contract"
  echo "Address:   $address"
  if [ -n "$args" ]; then
    echo "Args:      $args"
  fi
  echo "═══════════════════════════════════════════════════════════════"
  
  verify_monadscan "$address" "$contract" "$args"
  verify_socialscan "$address" "$contract" "$args"
}

# ══════════════════════════════════════════════════════════════════════════════
# Encode Constructor Arguments
# ══════════════════════════════════════════════════════════════════════════════

echo "Encoding constructor arguments..."

# MockToken("Pool Token", "POOL")
POOL_TOKEN_ARGS=$(cast abi-encode "constructor(string,string)" "Pool Token" "POOL")

# MockToken("PRLL", "PRLL")
PRLL_TOKEN_ARGS=$(cast abi-encode "constructor(string,string)" "PRLL" "PRLL")

# BondRegistry(address _bondToken)
BOND_REGISTRY_ARGS=$(cast abi-encode "constructor(address)" "$PRLL_TOKEN")

# MockSwapModule(address _pool)
MOCK_SWAP_ARGS=$(cast abi-encode "constructor(address)" "$PARALLEL_POOL")

# MockArbModule(address _pool)
MOCK_ARB_ARGS=$(cast abi-encode "constructor(address)" "$PARALLEL_POOL")

# MockBadModule(address _pool)
MOCK_BAD_ARGS=$(cast abi-encode "constructor(address)" "$PARALLEL_POOL")

# LaneVault(address _token, address _pool, uint256 _laneId)
LANE_VAULT_0_ARGS=$(cast abi-encode "constructor(address,address,uint256)" "$POOL_TOKEN" "$PARALLEL_POOL" 0)
LANE_VAULT_1_ARGS=$(cast abi-encode "constructor(address,address,uint256)" "$POOL_TOKEN" "$PARALLEL_POOL" 1)
LANE_VAULT_2_ARGS=$(cast abi-encode "constructor(address,address,uint256)" "$POOL_TOKEN" "$PARALLEL_POOL" 2)
LANE_VAULT_3_ARGS=$(cast abi-encode "constructor(address,address,uint256)" "$POOL_TOKEN" "$PARALLEL_POOL" 3)

echo "Constructor arguments encoded."

# ══════════════════════════════════════════════════════════════════════════════
# Verify All Contracts
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║        VERIFYING ALL CONTRACTS ON MONADSCAN + SOCIALSCAN                 ║"
echo "║                     Monad Mainnet (Chain 143)                            ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"

# ParallelPool constructor args
# ParallelPool(token, bondRegistry, minBond, feeBps, numLanes, feeReceiver)
MIN_BOND="1000000000000000000000"  # 1000 ether
FEE_BPS="10"
NUM_LANES="4"
PARALLEL_POOL_ARGS=$(cast abi-encode "constructor(address,address,uint256,uint256,uint256,address)" \
  "$POOL_TOKEN" "$BOND_REGISTRY" "$MIN_BOND" "$FEE_BPS" "$NUM_LANES" "$DEPLOYER")

# Verify ParallelPool (already verified on Monadscan, but verify on SocialScan)
echo ""
echo "Note: ParallelPool ($PARALLEL_POOL) is already verified on Monadscan."
verify_socialscan "$PARALLEL_POOL" "src/ParallelPool.sol:ParallelPool" "$PARALLEL_POOL_ARGS"

# Tokens
verify_both "$POOL_TOKEN" "src/mocks/MockToken.sol:MockToken" "$POOL_TOKEN_ARGS"
verify_both "$PRLL_TOKEN" "src/mocks/MockToken.sol:MockToken" "$PRLL_TOKEN_ARGS"

# Core contracts
verify_both "$BOND_REGISTRY" "src/BondRegistry.sol:BondRegistry" "$BOND_REGISTRY_ARGS"

# Mock modules
verify_both "$MOCK_SWAP_MODULE" "src/mocks/MockSwapModule.sol:MockSwapModule" "$MOCK_SWAP_ARGS"
verify_both "$MOCK_ARB_MODULE" "src/mocks/MockArbModule.sol:MockArbModule" "$MOCK_ARB_ARGS"
verify_both "$MOCK_BAD_MODULE" "src/mocks/MockBadModule.sol:MockBadModule" "$MOCK_BAD_ARGS"

# Lane Vaults
verify_both "$LANE_VAULT_0" "src/LaneVault.sol:LaneVault" "$LANE_VAULT_0_ARGS"
verify_both "$LANE_VAULT_1" "src/LaneVault.sol:LaneVault" "$LANE_VAULT_1_ARGS"
verify_both "$LANE_VAULT_2" "src/LaneVault.sol:LaneVault" "$LANE_VAULT_2_ARGS"
verify_both "$LANE_VAULT_3" "src/LaneVault.sol:LaneVault" "$LANE_VAULT_3_ARGS"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                        VERIFICATION COMPLETE                              ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Check verification status at:"
echo "  Monadscan:   https://monadscan.com/address/<ADDRESS>#code"
echo "  SocialScan:  https://monad.socialscan.io/address/<ADDRESS>#code"
echo ""
