#!/usr/bin/env bash
set -euo pipefail

# lib.sh lives at /app/scripts/lib.sh (full repo COPY'd to /app). It runs
# `cd $REPO_ROOT` via setup(), so we don't cd here.
source /app/scripts/lib.sh
setup   # cd /app + load .env if present

ENV="${SUI_NETWORK:-localnet}"

# ── Determine RPC URL ────────────────────────────────────────────────────────
case "$ENV" in
    testnet)  RPC_URL="${SUI_RPC_URL:-https://fullnode.testnet.sui.io:443}" ;;
    devnet)   RPC_URL="${SUI_RPC_URL:-https://fullnode.devnet.sui.io:443}" ;;
    mainnet)  RPC_URL="${SUI_RPC_URL:-https://fullnode.mainnet.sui.io:443}" ;;
    localnet) RPC_URL="${SUI_RPC_URL:-http://127.0.0.1:9000}" ;;
    *)        echo "Error: Invalid SUI_NETWORK '$ENV'"; exit 1 ;;
esac

echo "======================================"
echo "  Environment : $ENV"
echo "  RPC URL     : $RPC_URL"
echo "======================================"

# ── Sui client config + active env (env-neutral helpers from lib.sh) ──────────
sui_init_config "$ENV" "$RPC_URL"
ensure_client_env "$ENV" "$RPC_URL"
echo "Active environment: $(sui client active-env)"

# ── Import deployer key (idempotent; echoes 0x address) ───────────────────────
if [ -z "${DEPLOYER_PRIVATE_KEY:-}" ]; then
    echo "Error: DEPLOYER_PRIVATE_KEY is not set (via .env or env var)"
    exit 1
fi

DEPLOYER_ADDRESS=$(import_key "$DEPLOYER_PRIVATE_KEY")
if [ -z "$DEPLOYER_ADDRESS" ]; then
    echo "Error: Could not determine deployer address from DEPLOYER_PRIVATE_KEY"
    exit 1
fi

echo "Setting active address: $DEPLOYER_ADDRESS"
sui client switch --address "$DEPLOYER_ADDRESS"
echo ""

# ── Deploy world ─────────────────────────────────────────────────────────────
# Deploys core + character + inventory + metadata to the target network and writes the deployment
# manifest. MVR publishing is intentionally out of scope here (separate
# workstream); this image only publishes the packages on-chain.
echo "======================================"
echo "  Deploying world contracts to $ENV ..."
echo "======================================"
./scripts/deploy-world.sh "$ENV"

echo ""
echo "======================================"
echo "  Deployment complete."
echo "  Manifest: deployments/$ENV/world.json"
echo "======================================"
