#!/usr/bin/env bash
# CI entrypoint: start local Sui node, create keys, fund, generate .env, then exec CMD.
set -euo pipefail

SUI_CFG="${SUI_CONFIG_DIR:-/root/.sui}"
KEYSTORE="$SUI_CFG/sui.keystore"
CLIENT_YAML="$SUI_CFG/client.yaml"
INIT_MARKER="$SUI_CFG/.initialized"
APP_ENV="/app/.env"
APP_ENV_EXAMPLE="/app/env.example"
ACCOUNTS_JSON="${ACCOUNTS_JSON:-/app/docker/genesis/accounts.json}"

# ---------- first-run: import the fixed test keys ----------
if [ ! -f "$INIT_MARKER" ]; then
  echo "[ci] First run — importing fixed test keys from $ACCOUNTS_JSON..."
  if [ ! -f "$ACCOUNTS_JSON" ]; then
    echo "[ci] ERROR: accounts file not found at $ACCOUNTS_JSON" >&2
    exit 1
  fi
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

  echo "[ci] Importing keypairs from $ACCOUNTS_JSON..."
  while IFS= read -r key; do
    alias="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
    pk="$(jq -r --arg k "$key" '.accounts[$k].privateKey' "$ACCOUNTS_JSON")"
    if [ -z "$pk" ] || [ "$pk" = "null" ]; then
      echo "[ci] ERROR: no privateKey for '$key' in $ACCOUNTS_JSON" >&2; exit 1
    fi
    sui keytool import "$pk" ed25519 --alias "$alias" \
      || { echo "[ci] ERROR: failed to import $alias" >&2; exit 1; }
  done < <(jq -r '.accounts | keys[]' "$ACCOUNTS_JSON")
  touch "$INIT_MARKER"
  echo "[ci] Keys imported."
fi

# ---------- start local node ----------
echo "[ci] Creating data directory..."
mkdir -p /data/sui-localnet

echo "[ci] Running sui genesis..."
sui genesis --working-dir /data/sui-localnet --with-faucet

# Genesis writes fullnode.yaml; overwriting it breaks faucet tx execution on Sui 1.75.

echo "[ci] Starting local Sui node..."
sui start --network.config /data/sui-localnet --with-faucet &
NODE_PID=$!
trap 'kill "$NODE_PID" 2>/dev/null || true' EXIT

echo "[ci] Waiting for RPC on port 9000..."
for i in $(seq 1 30); do
  curl -sf -X POST http://127.0.0.1:9000 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"rpc.discover","id":1}' > /dev/null 2>&1 && break
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

# One faucet grant for the given alias, with retries.
faucet_once() {
  local alias="$1"
  sui client switch --address "$alias" >/dev/null
  for attempt in 1 2 3; do
    sui client faucet 2>&1 && return 0
    [ "$attempt" -eq 3 ] && { echo "[ci] Faucet failed for $alias" >&2; return 1; }
    sleep 2
  done
}

FAUCET_GRANTS="${FAUCET_GRANTS:-5}"
SPONSOR_FAUCET_GRANTS="${SPONSOR_FAUCET_GRANTS:-50}"
echo "[ci] Funding GOVERNOR, ADMIN, PLAYER from faucet ($FAUCET_GRANTS grants each)..."
for alias in GOVERNOR ADMIN PLAYER; do
  for _ in $(seq 1 "$FAUCET_GRANTS"); do
    faucet_once "$alias" || exit 1
    sleep 1
  done
done

echo "[ci] Funding SPONSOR from faucet ($SPONSOR_FAUCET_GRANTS grants)..."
for _ in $(seq 1 "$SPONSOR_FAUCET_GRANTS"); do
  faucet_once SPONSOR || exit 1
  sleep 1
done

sui client switch --address SPONSOR >/dev/null
SPONSOR_ADDRESS="$(sui client active-address)"
# Pick one gas coin to deposit whole into the address balance.
SPONSOR_COIN="$(sui client gas --json 2>/dev/null | jq -r '.[0].gasCoinId // .[0].id // empty')"
if [ -n "$SPONSOR_COIN" ]; then
  echo "[ci] Depositing coin $SPONSOR_COIN into SPONSOR address balance..."
  sui client call \
    --package 0x2 --module coin --function send_funds \
    --type-args 0x2::sui::SUI \
    --args "$SPONSOR_COIN" "$SPONSOR_ADDRESS" \
    --gas-budget 100000000 \
    || echo "[ci] WARN: send_funds failed; sponsor still has its coin balance" >&2
else
  echo "[ci] WARN: no sponsor coin found; skipping address-balance deposit" >&2
fi

sui client switch --address ADMIN

# ---------- export keys and generate /app/.env ----------
get_address() { sui keytool export --key-identity "$1" --json 2>/dev/null | jq -r '.key.suiAddress'; }
get_key()     { sui keytool export --key-identity "$1" --json 2>/dev/null | jq -r '.exportedPrivateKey'; }

require_val() {
  if [ -z "$2" ] || [ "$2" = "null" ]; then
    echo "[ci] ERROR: failed to export $1" >&2; exit 1
  fi
}

GOVERNOR_ADDRESS=$(get_address GOVERNOR)
ADMIN_ADDRESS=$(get_address ADMIN)
SPONSOR_ADDRESS=$(get_address SPONSOR)
PLAYER_ADDRESS=$(get_address PLAYER)
GOVERNOR_PRIVATE_KEY=$(get_key GOVERNOR)
ADMIN_PRIVATE_KEY=$(get_key ADMIN)
SPONSOR_PRIVATE_KEY=$(get_key SPONSOR)
PLAYER_PRIVATE_KEY=$(get_key PLAYER)

for var in GOVERNOR_ADDRESS ADMIN_ADDRESS SPONSOR_ADDRESS PLAYER_ADDRESS \
           GOVERNOR_PRIVATE_KEY ADMIN_PRIVATE_KEY SPONSOR_PRIVATE_KEY PLAYER_PRIVATE_KEY; do
  require_val "$var" "${!var}"
done

if [ -f "$APP_ENV_EXAMPLE" ]; then
  echo "[ci] Generating .env from env.example..."
  sed -e 's/\r$//' "$APP_ENV_EXAMPLE" | \
  sed -e "s|^SUI_NETWORK=.*|SUI_NETWORK=localnet|" \
      -e "s|^ADMIN_ADDRESS=.*|ADMIN_ADDRESS=$ADMIN_ADDRESS|" \
      -e "s|^SPONSOR_ADDRESSES=.*|SPONSOR_ADDRESSES=$ADMIN_ADDRESS,$SPONSOR_ADDRESS|" \
      -e "s|^GOVERNOR_PRIVATE_KEY=.*|GOVERNOR_PRIVATE_KEY=$GOVERNOR_PRIVATE_KEY|" \
      -e "s|^ADMIN_PRIVATE_KEY=.*|ADMIN_PRIVATE_KEY=$ADMIN_PRIVATE_KEY|" \
      -e "s|^PLAYER_A_PRIVATE_KEY=.*|PLAYER_A_PRIVATE_KEY=$PLAYER_PRIVATE_KEY|" \
      -e "s|^PLAYER_B_PRIVATE_KEY=.*|PLAYER_B_PRIVATE_KEY=$ADMIN_PRIVATE_KEY|" \
  > "$APP_ENV"
  echo "[ci] .env written."
else
  echo "[ci] WARN: env.example not found, skipping .env generation" >&2
fi

if [ $# -eq 1 ]; then
  echo "[ci] Localnet ready. Deploying and configuring world..."

  cd /app
  export CI="${CI:-true}"

  echo "[ci] Switching to GOVERNOR for deployment..."
  sui client switch --address GOVERNOR >/dev/null

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

    # create-character reads SUI_NETWORK from .env (localnet) and assigns a
    # character to PLAYER_A = the player key.
    echo "[ci] Seeding a character for the player..."
    DELAY_SECONDS="${DELAY_SECONDS:-3}" pnpm create-character \
      || { echo "[ci] ERROR: failed to seed player character" >&2; exit 1; }

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

    # Unmounted copies used at runtime to seed an empty host bind mount at /data/deployment.
    echo "[ci] Copying extracted object ids to /opt/world-contracts/extracted-object-ids.json..."
    mkdir -p /opt/world-contracts
    cp deployments/localnet/extracted-object-ids.json /opt/world-contracts/extracted-object-ids.json

    echo "[ci] Copying accounts to /opt/world-contracts/accounts.json..."
    cp "$ACCOUNTS_JSON" /opt/world-contracts/accounts.json
  fi
else
  echo "[ci] Localnet ready. Running command..."
  exec "$@"
fi
