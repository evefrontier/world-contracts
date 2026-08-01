#!/usr/bin/env bash
# Deploy the world Move packages (core, then character) to a deployment env.
# Assumes the target node is already running (for localnet, start it separately).
#
# Usage: ./scripts/deploy-world.sh [localnet|dev|test|uat|live] [deploy|publish|upgrade]
source "$(dirname "$0")/lib.sh"

# Packages in dependency order (character/inventory depend on core; freight on both).
PACKAGES=(core character inventory freight)

setup
ENV=$(get_env "${1:-}")
MODE="${2:-publish}"
NETWORK=$(get_network "$ENV")
DEPLOY_DIR="deployments/$ENV"
mkdir -p "$DEPLOY_DIR"
start_logging "$ENV" "deploy-world ($MODE)"

# `deploy` (workflow term for a new lineage) is a synonym for `publish`.
case "$MODE" in
    deploy|publish) MODE="publish" ;;
    upgrade) ;;
    *) echo "Usage: $0 [localnet|dev|test|uat|live] [deploy|publish|upgrade]" >&2; exit 1 ;;
esac

ensure_client_env "$ENV" "$(get_rpc "$ENV")"

# localnet test-publishes into a shared ephemeral pubfile; named envs use the
# committed Published.toml maintained by sui.
PUBFILE=""
if [[ "$ENV" == "localnet" ]]; then
    PUBFILE="$REPO_ROOT/$DEPLOY_DIR/Pub.$ENV.toml"
    rm -f "$PUBFILE" "$REPO_ROOT"/contracts/*/Pub."$ENV".toml
fi

echo "Running '$MODE' for [${PACKAGES[*]}] to $ENV (network: $NETWORK) ..."
for pkg in "${PACKAGES[@]}"; do
    if [[ "$MODE" == "upgrade" ]]; then
        upgrade "$pkg" "$ENV" "$DEPLOY_DIR/$pkg.publish.json"
    else
        publish "$pkg" "$ENV" "$PUBFILE" "$DEPLOY_DIR/$pkg.publish.json"
    fi
done

CHAIN_ID=$(sui client chain-identifier)
pnpm exec tsx ts-scripts/build-manifest.ts "$DEPLOY_DIR" "$ENV" "$CHAIN_ID" "${PACKAGES[@]}"

# Seed the AdminACL from ADMIN_ADDRESS / SPONSOR_ADDRESSES in the env
echo "Configuring admins/sponsors for $ENV ..."
ENV="$ENV" pnpm --filter @evefrontier/world-sdk configure:admins

echo "Done ('$MODE') world to $ENV."
echo "  Manifest: $DEPLOY_DIR/world.json"
echo "  Log:      $DEPLOY_DIR/deploy.log"
