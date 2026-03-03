#!/usr/bin/env bash
# CI entrypoint: start local Sui node, create keys, fund, generate .env, then exec CMD.
set -euo pipefail

SUI_CFG="${SUI_CONFIG_DIR:-/root/.sui}"
KEYSTORE="$SUI_CFG/sui.keystore"
CLIENT_YAML="$SUI_CFG/client.yaml"
INIT_MARKER="$SUI_CFG/.initialized"
APP_ENV="/app/.env"
APP_ENV_EXAMPLE="/app/env.example"

# ---------- first-run: create keys ----------
if [ ! -f "$INIT_MARKER" ]; then
  echo "[ci] First run — initialising keys..."
  mkdir -p "$SUI_CFG"
  printf '%s' '[]' > "$KEYSTORE"
  cat > "$CLIENT_YAML" << EOF
---
keystore:
  File: $KEYSTORE
envs:
  - alias: localnet
    rpc: "http://127.0.0.1:9000"
  - alias: testnet
    rpc: "https://fullnode.testnet.sui.io"
active_env: localnet
active_address: ~
EOF

  printf 'y\n' | sui client switch --env localnet 2>/dev/null || true

  echo "[ci] Creating keypairs: ADMIN, PLAYER_A, PLAYER_B..."
  for alias in ADMIN PLAYER_A PLAYER_B; do
    printf '\n' | sui client new-address ed25519 "$alias" \
      || { echo "[ci] ERROR: failed to create $alias" >&2; exit 1; }
  done
  touch "$INIT_MARKER"
  echo "[ci] Keys created."
fi

# ---------- start local node ----------
echo "[ci] Starting local Sui node..."
sui start --with-faucet --force-regenesis &
NODE_PID=$!
trap 'kill "$NODE_PID" 2>/dev/null || true' EXIT

echo "[ci] Waiting for RPC on port 9000..."
rpc_ready() {
  curl -sf -X POST http://127.0.0.1:9000 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"rpc.discover","id":1}' > /dev/null 2>&1
}
for i in $(seq 1 30); do
  rpc_ready && break
  if [ "$i" -eq 30 ]; then
    echo "[ci] ERROR: RPC did not become ready" >&2
    kill "$NODE_PID" 2>/dev/null || true
    exit 1
  fi
  sleep 1
done
sleep 2
echo "[ci] RPC ready."

# ---------- fund accounts ----------
printf 'y\n' | sui client switch --env localnet 2>/dev/null || true
echo "[ci] Funding accounts from faucet..."
for alias in ADMIN PLAYER_A PLAYER_B; do
  sui client switch --address "$alias"
  for attempt in 1 2 3; do
    sui client faucet 2>&1 && break
    [ "$attempt" -eq 3 ] && { echo "[ci] Faucet failed for $alias" >&2; exit 1; }
    sleep 2
  done
done
sui client switch --address ADMIN

# ---------- export keys and generate /app/.env ----------
get_address() { sui keytool export --key-identity "$1" --json 2>/dev/null | jq -r '.key.suiAddress'; }
get_key()     { sui keytool export --key-identity "$1" --json 2>/dev/null | jq -r '.exportedPrivateKey'; }

require_val() {
  if [ -z "$2" ] || [ "$2" = "null" ]; then
    echo "[ci] ERROR: failed to export $1" >&2; exit 1
  fi
}

ADMIN_ADDRESS=$(get_address ADMIN)
PLAYER_A_ADDRESS=$(get_address PLAYER_A)
PLAYER_B_ADDRESS=$(get_address PLAYER_B)
ADMIN_PRIVATE_KEY=$(get_key ADMIN)
PLAYER_A_PRIVATE_KEY=$(get_key PLAYER_A)
PLAYER_B_PRIVATE_KEY=$(get_key PLAYER_B)

for var in ADMIN_ADDRESS PLAYER_A_ADDRESS PLAYER_B_ADDRESS \
           ADMIN_PRIVATE_KEY PLAYER_A_PRIVATE_KEY PLAYER_B_PRIVATE_KEY; do
  require_val "$var" "${!var}"
done

if [ -f "$APP_ENV_EXAMPLE" ]; then
  echo "[ci] Generating .env from env.example..."
  sed -e 's/\r$//' "$APP_ENV_EXAMPLE" | \
  sed -e "s|^SUI_NETWORK=.*|SUI_NETWORK=localnet|" \
      -e "s|^ADMIN_ADDRESS=.*|ADMIN_ADDRESS=$ADMIN_ADDRESS|" \
      -e "s|^SPONSOR_ADDRESSES=.*|SPONSOR_ADDRESSES=$ADMIN_ADDRESS|" \
      -e "s|^ADMIN_PRIVATE_KEY=.*|ADMIN_PRIVATE_KEY=$ADMIN_PRIVATE_KEY|" \
      -e "s|^GOVERNOR_PRIVATE_KEY=.*|GOVERNOR_PRIVATE_KEY=$ADMIN_PRIVATE_KEY|" \
      -e "s|^PLAYER_A_PRIVATE_KEY=.*|PLAYER_A_PRIVATE_KEY=$PLAYER_A_PRIVATE_KEY|" \
      -e "s|^PLAYER_B_PRIVATE_KEY=.*|PLAYER_B_PRIVATE_KEY=$PLAYER_B_PRIVATE_KEY|" \
  > "$APP_ENV"
  echo "[ci] .env written."
else
  echo "[ci] WARN: env.example not found, skipping .env generation" >&2
fi

# ---------- default: deploy + integration test (when no CMD) ----------
if [ $# -eq 0 ]; then
  echo "[ci] Localnet ready. Running deploy + integration tests..."
  cd /app
  export CI="${CI:-true}"
  pnpm install --frozen-lockfile
  pnpm deploy-world localnet
  pnpm run configure-world localnet
  pnpm deploy-builder-ext localnet
  chmod +x ./scripts/run-integration-test.sh
  DELAY_SECONDS="${DELAY_SECONDS:-3}" ./scripts/run-integration-test.sh
else
  echo "[ci] Localnet ready. Running command..."
  exec "$@"
fi
