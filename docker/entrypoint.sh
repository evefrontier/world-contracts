#!/usr/bin/env bash
# Docker entrypoint: set up Sui environment, import keys, deploy and configure.
set -euo pipefail

cd /app

# ── Load .env ────────────────────────────────────────────────────────────────
if [ -f .env ]; then
    set -a && source .env && set +a
else
    echo "Error: .env file not found. Mount it to /app/.env"
    exit 1
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

if [ -z "${GOVERNOR_PRIVATE_KEY:-}" ]; then
    echo "Error: GOVERNOR_PRIVATE_KEY is not set in .env"
    exit 1
fi

DEPLOYER_ADDRESS=$(import_key "GOVERNOR_PRIVATE_KEY (deployer)" "$GOVERNOR_PRIVATE_KEY")


if [ -z "$DEPLOYER_ADDRESS" ]; then
    echo "Error: Could not determine deployer address from GOVERNOR_PRIVATE_KEY"
    exit 1
fi

echo "Setting active address: $DEPLOYER_ADDRESS"
sui client switch --address "$DEPLOYER_ADDRESS"
echo ""

# ── Deploy world ─────────────────────────────────────────────────────────────
echo "======================================"
echo "  Deploying world contracts..."
echo "======================================"   
./scripts/deploy-world.sh "$ENV"

echo ""
echo "======================================"
echo "  Configuring world..."
echo "======================================"
./scripts/configure-world.sh "$ENV"

echo ""
echo "======================================"
echo "  Deployment & configuration complete!"
echo "======================================"
