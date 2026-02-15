#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [ ! -f ".env" ]; then
  echo "Missing .env. Create it from .env.example and set ACCOUNT_NAME."
  exit 1
fi

# shellcheck disable=SC1091
source ".env"

if [ -z "${MONAD_MAINNET_RPC_URL:-}" ]; then
  echo "MONAD_MAINNET_RPC_URL is not set."
  exit 1
fi

if [ -z "${ACCOUNT_NAME:-}" ]; then
  echo "ACCOUNT_NAME is not set."
  exit 1
fi

if [ -z "${DEPLOYER_ADDRESS:-}" ]; then
  echo "DEPLOYER_ADDRESS is not set in .env."
  exit 1
fi

# Verify Monad Foundry is installed (required for accurate gas estimation)
if ! forge --version 2>&1 | grep -q "monad"; then
  echo "WARNING: Monad Foundry not detected. Standard Foundry will underestimate gas on Monad."
  echo "Install: curl -L https://raw.githubusercontent.com/category-labs/foundry/monad/foundryup/install | bash && foundryup --network monad"
  echo ""
fi

echo "Running demo on Monad MAINNET..."
echo "RPC: $MONAD_MAINNET_RPC_URL"
echo "Account: $ACCOUNT_NAME"
echo "Sender: $DEPLOYER_ADDRESS"
echo ""

forge script script/Demo.s.sol \
  --rpc-url "$MONAD_MAINNET_RPC_URL" \
  --account "$ACCOUNT_NAME" \
  --sender "$DEPLOYER_ADDRESS" \
  --broadcast --slow -vvvv
