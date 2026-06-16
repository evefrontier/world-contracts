#!/usr/bin/env bash
# Deploy the world Move packages (core, then character) to a network.
# Assumes the target node is already running (for localnet, start it separately).
# Usage: ./scripts/deploy-world.sh [localnet|testnet|mainnet|devnet]
source "$(dirname "$0")/lib.sh"

# Packages in dependency order (character depends on core).
PACKAGES=(core character)

setup
ENV=$(get_env "${1:-}")
DEPLOY_DIR="deployments/$ENV"
mkdir -p "$DEPLOY_DIR"
start_logging "$ENV" "deploy-world"

# Single shared pubfile so local deps resolve each other's published ids.
# Lives under deployments/ (gitignored); ephemeral per node session.
PUBFILE="$REPO_ROOT/$DEPLOY_DIR/Pub.$ENV.toml"
rm -f "$PUBFILE" "$REPO_ROOT"/contracts/*/Pub."$ENV".toml

# Pin the active env to the deploy target so publish + chain-identifier never
# run against a stale selection (which would deploy to the wrong network).
sui client switch --env "$ENV" >/dev/null

echo "Deploying [${PACKAGES[*]}] to $ENV ..."
for pkg in "${PACKAGES[@]}"; do
    publish "$pkg" "$ENV" "$PUBFILE" "$DEPLOY_DIR/$pkg.publish.json"
done

CHAIN_ID=$(sui client chain-identifier)
pnpm exec tsx ts-scripts/build-manifest.ts "$DEPLOY_DIR" "$CHAIN_ID" "${PACKAGES[@]}"

echo "Deployed world to $ENV."
echo "  Manifest: $DEPLOY_DIR/world.json"
echo "  Log:      $DEPLOY_DIR/deploy.log"
