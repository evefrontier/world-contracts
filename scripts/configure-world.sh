#!/usr/bin/env bash
# Configure world after deployment.
# Usage: ./scripts/configure-world.sh [localnet|testnet|mainnet|devnet]
source "$(dirname "$0")/lib.sh"

setup
ENV=$(get_env "${1:-}")
mkdir -p "deployments/$ENV"
start_logging "$ENV" "configure-world"
export SUI_NETWORK="$ENV"

echo "--- setup-access ---"
pnpm exec tsx ts-scripts/access/setup-access.ts

echo "--- configure-fuel-energy ---"
pnpm exec tsx ts-scripts/network-node/configure-fuel-energy.ts

echo "--- configure-gate-distance ---"
pnpm exec tsx ts-scripts/gate/configure-distance.ts

echo "World configured for $ENV."