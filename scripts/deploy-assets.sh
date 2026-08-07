#!/usr/bin/env bash
# Deploy assets (EVE token) package and finalize CoinRegistry registration.
# Usage: ./scripts/deploy-assets.sh [localnet|testnet|mainnet|devnet]
source "$(dirname "$0")/lib.sh"

setup
ENV=$(get_env "${1:-}")
rm -rf contracts/assets/Pub.*.toml
mkdir -p "deployments/$ENV"
start_logging "$ENV" "deploy-assets"

echo "--- pnpm i ---"
pnpm i

echo "--- sui client publish ---"
publish assets "deployments/$ENV/assets_package.json" "$ENV"

echo "--- extract-object-ids ---"
export SUI_NETWORK="$ENV"
pnpm exec tsx ts-scripts/utils/extract-object-ids.ts

echo "--- finalize EVE currency ---"
pnpm exec tsx ts-scripts/assets/finalize-eve-currency.ts

echo "Deployed assets to $ENV. Output: deployments/$ENV/"
echo "Log: deployments/$ENV/deploy.log"
