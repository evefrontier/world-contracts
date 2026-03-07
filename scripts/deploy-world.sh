#!/usr/bin/env bash
# Deploy world contracts.
# Usage: ./scripts/deploy-world.sh [localnet|testnet|mainnet|devnet|testnet_utopia|testnet_stillness]
source "$(dirname "$0")/lib.sh"

setup
ENV=$(get_env "${1:-}")
DEPLOY_DIR=$(get_deploy_dir "$ENV")
pnpm clean
rm -rf contracts/world/Pub.*.toml
mkdir -p "deployments/$DEPLOY_DIR"
start_logging "$DEPLOY_DIR" "deploy-world"

echo "--- pnpm i ---"
pnpm i

echo "--- sui client publish ---"
publish world "deployments/$DEPLOY_DIR/world_package.json" "$ENV"

echo "--- extract-object-ids ---"
export SUI_NETWORK="$DEPLOY_DIR"
pnpm exec tsx ts-scripts/utils/extract-object-ids.ts

echo "Deployed world to $ENV. Output: deployments/$DEPLOY_DIR/"
echo "Log: deployments/$DEPLOY_DIR/deploy.log"
