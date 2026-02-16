#!/usr/bin/env bash
# Deploy world contracts.
# Usage: ./scripts/deploy-world.sh [localnet|testnet|mainnet|devnet]
source "$(dirname "$0")/lib.sh"

setup
ENV=$(get_env "${1:-}")
pnpm clean
rm -rf contracts/world/Pub.*.toml
mkdir -p "deployments/$ENV"
start_logging "$ENV" "deploy-world"

echo "--- pnpm i ---"
pnpm i

echo "--- sui client publish ---"
publish world "deployments/$ENV/world_package.json" "$ENV"

echo "--- extract-object-ids ---"
export SUI_NETWORK="$ENV"
pnpm exec tsx ts-scripts/utils/extract-object-ids.ts

echo "Deployed world to $ENV. Output: deployments/$ENV/"
echo "Log: deployments/$ENV/deploy.log"
