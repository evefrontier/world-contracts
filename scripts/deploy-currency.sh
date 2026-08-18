#!/usr/bin/env bash
# Deploy the EVE currency package (independent of world redeploys).
#
# Usage: ./scripts/deploy-currency.sh [localnet|dev|test|uat|live] [deploy|publish|upgrade]
# For localnet: run deploy-world.sh first so deployments/<env>/Pub.<env>.toml exists.
source "$(dirname "$0")/lib.sh"

PKG=currency

setup
ENV=$(get_env "${1:-}")
MODE="${2:-publish}"
NETWORK=$(get_network "$ENV")
DEPLOY_DIR="deployments/$ENV"
mkdir -p "$DEPLOY_DIR"
start_logging "$ENV" "deploy-currency ($MODE)"

case "$MODE" in
    deploy|publish) MODE="publish" ;;
    upgrade) ;;
    *) echo "Usage: $0 [localnet|dev|test|uat|live] [deploy|publish|upgrade]" >&2; exit 1 ;;
esac

ensure_client_env "$ENV" "$(get_rpc "$ENV")"

PUBFILE=""
if [[ "$ENV" == "localnet" ]]; then
    PUBFILE="$REPO_ROOT/$DEPLOY_DIR/Pub.$ENV.toml"
    if [[ ! -f "$PUBFILE" ]]; then
        echo "ERROR: missing $PUBFILE — run ./scripts/deploy-world.sh localnet first." >&2
        exit 1
    fi
fi

echo "Running '$MODE' for [$PKG] to $ENV (network: $NETWORK) ..."
if [[ "$MODE" == "upgrade" ]]; then
    upgrade "$PKG" "$ENV" "$DEPLOY_DIR/$PKG.publish.json"
else
    publish "$PKG" "$ENV" "$PUBFILE" "$DEPLOY_DIR/$PKG.publish.json"
fi

CHAIN_ID=$(sui client chain-identifier)
pnpm exec tsx ts-scripts/build-manifest.ts "$DEPLOY_DIR" "$ENV" "$CHAIN_ID" "$PKG"

echo "Finalizing EVE currency for $ENV ..."
ENV="$ENV" pnpm --filter @evefrontier/world-sdk finalize:eve

echo "Done ('$MODE') currency to $ENV."
echo "  Manifest: $DEPLOY_DIR/world.json"
echo "  Log:      $DEPLOY_DIR/deploy.log"
