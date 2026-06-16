#!/usr/bin/env bash
set -euo pipefail

cd /app

# ── Load .env if present (optional; CI may inject env vars instead) ───────────
if [ -f .env ]; then
    set -a && source .env && set +a
fi

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

# ── Initialize Sui client config ─────────────────────────────────────────────
if [ ! -f "$HOME/.sui/sui_config/client.yaml" ]; then
    echo "Initializing Sui client configuration..."
    mkdir -p "$HOME/.sui/sui_config"

    cat > "$HOME/.sui/sui_config/client.yaml" <<EOF
---
keystore:
  File: $HOME/.sui/sui_config/sui.keystore
envs:
  - alias: $ENV
    rpc: "$RPC_URL"
    ws: ~
    basic_auth: ~
active_env: $ENV
active_address: ~
EOF
    echo "[]" > "$HOME/.sui/sui_config/sui.keystore"
    echo "Sui client configured for $ENV"
else
    echo "Sui client configuration already exists"
    if ! sui client envs 2>/dev/null | grep -qw "$ENV"; then
        sui client new-env --alias "$ENV" --rpc "$RPC_URL" 2>/dev/null || true
    fi
fi

sui client switch --env "$ENV"
echo "Active environment: $(sui client active-env)"

# ── Import private keys into keystore ────────────────────────────────────────
import_key() {
    local name=$1 key=$2
    [ -z "$key" ] && return 0
    echo "Importing $name..." >&2
    set +e
    output=$(sui keytool import "$key" ${KEY_SCHEME:-ed25519} 2>&1)
    rc=$?
    set -e
    if [ $rc -ne 0 ] && ! echo "$output" | grep -qi "already exists"; then
        echo "  Warning: $output" >&2
        return 1
    fi
    echo "$output" | grep -oE '0x[a-fA-F0-9]{64}' | head -n 1
}

if [ -z "${DEPLOYER_PRIVATE_KEY:-}" ]; then
    echo "Error: DEPLOYER_PRIVATE_KEY is not set (via .env or env var)"
    exit 1
fi

DEPLOYER_ADDRESS=$(import_key "DEPLOYER_PRIVATE_KEY" "$DEPLOYER_PRIVATE_KEY")


if [ -z "$DEPLOYER_ADDRESS" ]; then
    echo "Error: Could not determine deployer address from DEPLOYER_PRIVATE_KEY"
    exit 1
fi

echo "Setting active address: $DEPLOYER_ADDRESS"
sui client switch --address "$DEPLOYER_ADDRESS"
echo ""

# ── Deploy world ─────────────────────────────────────────────────────────────
# Deploys core + character to the target network and writes the deployment
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
