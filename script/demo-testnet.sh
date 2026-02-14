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

if [ -z "${MONAD_RPC_URL:-}" ]; then
  echo "MONAD_RPC_URL is not set."
  exit 1
fi

if [ -z "${ACCOUNT_NAME:-}" ]; then
  echo "ACCOUNT_NAME is not set."
  exit 1
fi

echo "Running demo on Monad testnet..."
forge script script/Demo.s.sol --rpc-url "$MONAD_RPC_URL" --account "$ACCOUNT_NAME" --broadcast -vvvv
