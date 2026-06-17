#!/usr/bin/env bash
# Deploy the world Move packages (core, then character) to a deployment env.
# Assumes the target node is already running (for localnet, start it separately).
#
# Usage: ./scripts/deploy-world.sh [localnet|dev|test|uat|live] [publish|upgrade]
source "$(dirname "$0")/lib.sh"

# Packages in dependency order (character depends on core).
PACKAGES=(core character)

setup
ENV=$(get_env "${1:-}")
MODE="${2:-publish}"
NETWORK=$(get_network "$ENV")
DEPLOY_DIR="deployments/$ENV"
mkdir -p "$DEPLOY_DIR"
start_logging "$ENV" "deploy-world ($MODE)"

case "$MODE" in
    publish|upgrade) ;;
    *) echo "Usage: $0 [localnet|dev|test|uat|live] [publish|upgrade]" >&2; exit 1 ;;
esac

sui client switch --env "$NETWORK" >/dev/null

# localnet uses an ephemeral shared pubfile (gitignored) so local deps resolve
# each other's published ids. Named envs use the committed Published.toml that
# `sui client publish/upgrade -e <env>` maintains per package — never deleted.
PUBFILE=""
if [[ "$ENV" == "localnet" ]]; then
    PUBFILE="$REPO_ROOT/$DEPLOY_DIR/Pub.$ENV.toml"
    rm -f "$PUBFILE" "$REPO_ROOT"/contracts/*/Pub."$ENV".toml
fi

echo "${MODE^} [${PACKAGES[*]}] to $ENV (network: $NETWORK) ..."
for pkg in "${PACKAGES[@]}"; do
    if [[ "$MODE" == "upgrade" ]]; then
        upgrade "$pkg" "$ENV" "$DEPLOY_DIR/$pkg.publish.json"
    else
        publish "$pkg" "$ENV" "$PUBFILE" "$DEPLOY_DIR/$pkg.publish.json"
    fi
done

CHAIN_ID=$(sui client chain-identifier)
pnpm exec tsx ts-scripts/build-manifest.ts "$DEPLOY_DIR" "$CHAIN_ID" "${PACKAGES[@]}"

echo "${MODE^}d world to $ENV."
echo "  Manifest: $DEPLOY_DIR/world.json"
echo "  Log:      $DEPLOY_DIR/deploy.log"
