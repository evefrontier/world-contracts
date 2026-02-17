#!/usr/bin/env bash
# Deploy builder-extension contracts.
# Usage: ./scripts/deploy-builder-ext.sh [localnet|testnet|mainnet|devnet]
# For localnet: deploy world first so Pub.localnet.toml has world's address.
source "$(dirname "$0")/lib.sh"

setup
ENV=$(get_env "${1:-}")
rm -rf contracts/extension_examples/Published.toml contracts/extension_examples/Pub.*.toml
mkdir -p "deployments/$ENV"
start_logging "$ENV" "deploy-builder-ext"

echo "--- pnpm i ---"
pnpm i

echo "--- sui client publish ---"
publish extension_examples "deployments/$ENV/builder_package.json" "$ENV"

echo "--- extract-object-ids ---"
export SUI_NETWORK="$ENV"
pnpm exec tsx ts-scripts/utils/extract-object-ids.ts

echo "Deployed builder-ext to $ENV. Output: deployments/$ENV/"
echo "Log: deployments/$ENV/deploy.log"
