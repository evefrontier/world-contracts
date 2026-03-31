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
echo "[ci] Creating data directory..."
mkdir -p /data/sui-localnet

echo "[ci] Running sui genesis..."
sui genesis --working-dir /data/sui-localnet --with-faucet

echo "[ci] Copying fullnode.yaml to data directory..."
cp /fullnode.yaml /data/sui-localnet/fullnode.yaml

echo "[ci] Starting local Sui node..."
sui start --network.config /data/sui-localnet --with-faucet &
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

if [ $# -eq 1 ]; then
  echo "[ci] Localnet ready. Deploying and configuring world..."

  cd /app
  export CI="${CI:-true}"

  pnpm install --frozen-lockfile
  pnpm deploy-world localnet
  pnpm run configure-world localnet
  pnpm deploy-builder-ext localnet

  if [ "$1" = "test" ]; then
    echo "[ci] Running integration tests..."

    chmod +x ./scripts/run-integration-test.sh
    DELAY_SECONDS="${DELAY_SECONDS:-3}" ./scripts/run-integration-test.sh
  elif [ "$1" = "snapshot" ]; then
    echo "[ci] Building snapshot image..."

    echo "[ci] Shutting down node..."
    if kill -0 "$NODE_PID" 2>/dev/null; then
      # Try graceful shutdown first (SIGTERM), with a bounded wait.
      echo "[ci] Node process signaled for shutdown..."
      kill "$NODE_PID" 2>/dev/null || true

      SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-60}"
      while kill -0 "$NODE_PID" 2>/dev/null && [ "$SHUTDOWN_TIMEOUT" -gt 0 ]; do
        echo "[ci] Waiting for node to shutdown... $SHUTDOWN_TIMEOUT seconds remaining"

        sleep 1
        SHUTDOWN_TIMEOUT=$((SHUTDOWN_TIMEOUT - 1))
      done

      if kill -0 "$NODE_PID" 2>/dev/null; then
        echo "[ci] Node did not exit gracefully, forcing termination..."
        kill -9 "$NODE_PID" 2>/dev/null || true
      fi

      # Ensure the process is fully reaped before proceeding.
      echo "[ci] Making sure the node process is fully reaped..."
      wait "$NODE_PID" 2>/dev/null || true
    else
      echo "[ci] Node process not running; skipping shutdown wait."
    fi

    echo "[ci] Replacing entrypoint with snapshot image entrypoint..."
    mv /entrypoint-snapshot-image.sh /entrypoint.sh
    chmod a+x /entrypoint.sh

    # Unmounted copy used at runtime to seed an empty host bind mount at /data/deployment.
    echo "[ci] Copying extracted object ids to /opt/world-contracts/extracted-object-ids.json..."
    mkdir -p /opt/world-contracts
    cp deployments/localnet/extracted-object-ids.json /opt/world-contracts/extracted-object-ids.json
  fi
else
  echo "[ci] Localnet ready. Running command..."
  exec "$@"
fi
