#!/usr/bin/env bash
# Integration / snapshot entrypoint for Dockerfile.integration.
#
# Brings up a DETERMINISTIC local Sui node: predefined, genesis-funded accounts
# (signed for by the well-known test private keys committed in
# /genesis/accounts.json), deploys the world packages, then dispatches on the
# mode argument:
#
#   test       run the SDK integration tests against the freshly deployed chain
#   snapshot   bake the chain state for the downstream snapshot image
#   <none>     leave the node running in the foreground as a plain localnet
set -euo pipefail

MODE="${1:-}"

SUI_CFG="${SUI_CONFIG_DIR:-/root/.sui}"
KEYSTORE="$SUI_CFG/sui.keystore"
CLIENT_YAML="$SUI_CFG/client.yaml"
DATA_DIR="/data/sui-localnet"
GENESIS_DIR="/genesis"
GENESIS_CONFIG="$GENESIS_DIR/genesis-config.yaml"
ACCOUNTS_JSON="$GENESIS_DIR/accounts.json"
STAGE_DIR="/opt/world-contracts"
RPC_URL="http://127.0.0.1:9000"
KEY_SCHEME="ed25519"

log() { echo "[integration] $*"; }

RPC_WAIT_ITERATIONS="${RPC_WAIT_ITERATIONS:-120}"

# Snapshot bake must reach epoch >= 1 so downstream tests that depend on
# epoch-1 cases don't fail against a sealed epoch-0 chain.
wait_for_epoch() {
  local min_epoch="${1:-1}"
  local epoch=0
  log "Waiting for epoch >= ${min_epoch}..."
  for i in $(seq 1 60); do
    ensure_node_up
    epoch="$(curl -sf -X POST "$RPC_URL" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"suix_getLatestSuiSystemState","params":[]}' \
      | jq -r '(.result.epoch // 0) | tonumber' || echo 0)"
    [ "$epoch" -ge "$min_epoch" ] && break
    sleep 2
  done
  if [ "${epoch:-0}" -lt "$min_epoch" ]; then
    log "ERROR: timed out waiting for epoch >= ${min_epoch}"
    exit 1
  fi
  log "Epoch is ${epoch}."
}

node_alive() { [ -n "${NODE_PID:-}" ] && kill -0 "$NODE_PID" 2>/dev/null; }

# Graceful node shutdown so RocksDB flushes before the snapshot is committed.
# Pass "final" to drop the EXIT trap (snapshot bake complete).
stop_node() {
  local clear_trap="${1:-}"
  local timeout="${SHUTDOWN_TIMEOUT:-60}"
  if node_alive; then
    kill "$NODE_PID" 2>/dev/null || true
    while node_alive && [ "$timeout" -gt 0 ]; do
      sleep 1
      timeout=$((timeout - 1))
    done
    if node_alive; then
      log "Node did not exit gracefully; forcing termination."
      kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    wait "$NODE_PID" 2>/dev/null || true
  fi
  if [ "$clear_trap" = "final" ]; then
    trap - EXIT
  fi
}

start_node() {
  log "Starting local Sui node (${START_ARGS[*]})..."
  sui start "${START_ARGS[@]}" >>"$NODE_LOG" 2>&1 &
  NODE_PID=$!
  trap 'kill "$NODE_PID" 2>/dev/null || true' EXIT
}

# 0 = RPC ready, 1 = process died, 2 = still alive but RPC never came up.
wait_for_rpc() {
  log "Waiting for RPC at $RPC_URL ..."
  local i
  for i in $(seq 1 "$RPC_WAIT_ITERATIONS"); do
    if ! node_alive; then
      return 1
    fi
    if curl -sf -X POST "$RPC_URL" -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"rpc.discover","id":1}' >/dev/null 2>&1; then
      # Confirm with a real `sui client` call too, but only every 3rd tick.
      if [ $((i % 3)) -eq 0 ] || [ "$i" -eq 1 ]; then
        if sui client gas "${ADDR[ADMIN]}" >/dev/null 2>&1; then
          return 0
        fi
      fi
    fi
    sleep 1
  done
  return 2
}

ensure_rpc() {
  local restarts=0
  local max="${NODE_RESTARTS:-3}"
  local wait_st
  while true; do
    wait_st=0
    wait_for_rpc || wait_st=$?
    if [ "$wait_st" -eq 0 ]; then
      log "RPC ready."
      return 0
    fi
    if [ "$wait_st" -eq 2 ]; then
      log "ERROR: RPC did not become ready"
      tail -n 100 "$NODE_LOG" || true
      exit 1
    fi
    restarts=$((restarts + 1))
    if [ "$restarts" -gt "$max" ]; then
      log "ERROR: node exited before RPC was ready (after ${max} restarts)"
      tail -n 100 "$NODE_LOG" || true
      exit 1
    fi
    log "WARN: node exited before RPC was ready; restart ${restarts}/${max}"
    start_node
  done
}

ensure_node_up() {
  if node_alive \
    && curl -sf -X POST "$RPC_URL" -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"rpc.discover","id":1}' >/dev/null 2>&1; then
    return 0
  fi
  log "WARN: node unhealthy; restarting"
  stop_node
  start_node
  ensure_rpc
}

# ── 1. Sui client config + import predefined accounts ────────────────────────
log "Initialising Sui client config at $SUI_CFG"
mkdir -p "$SUI_CFG"
printf '%s' '[]' > "$KEYSTORE"
cat > "$CLIENT_YAML" <<EOF
---
keystore:
  File: $KEYSTORE
envs:
  - alias: localnet
    rpc: "$RPC_URL"
  - alias: testnet
    rpc: "https://fullnode.testnet.sui.io:443"
active_env: localnet
active_address: ~
EOF

log "Importing predefined accounts from $ACCOUNTS_JSON..."
declare -A ADDR
declare -A PRIVKEY
while IFS=$'\t' read -r alias key expected; do
  sui keytool import "$key" "$KEY_SCHEME" --alias "$alias" >/dev/null 2>&1 \
    || { log "ERROR: failed to import $alias"; exit 1; }
  ADDR[$alias]="$(sui keytool export --key-identity "$alias" --json | jq -r '.key.suiAddress')"
  PRIVKEY[$alias]="$key"
  # The committed address is what downstream reads out of accounts.json, so a
  # key/address mismatch must fail the bake rather than ship a misleading file.
  if [ "${ADDR[$alias]}" != "$expected" ]; then
    log "ERROR: $alias key derives ${ADDR[$alias]}, but accounts.json says $expected"; exit 1
  fi
  log "  $alias -> ${ADDR[$alias]}"
done < <(jq -r '.accounts | to_entries[] | [.key, .value.privateKey, .value.address] | @tsv' "$ACCOUNTS_JSON")

sui client switch --address "${ADDR[ADMIN]}" >/dev/null
export WORLD_ADMIN_ADDRESS="${ADDR[ADMIN]}"
export SPONSOR_ADDRESSES="${ADDR[SPONSOR]}"
export SUI_PRIVATE_KEY="${PRIVKEY[ADMIN]}"

# ── 2. Deterministic genesis ─────────────────────────────────────────────────
GAS_PER_COIN="${GENESIS_GAS_PER_COIN:-30000000000000000}"
GAS_RESERVE="${GENESIS_GAS_RESERVE:-$GAS_PER_COIN}"
TOTAL_FUNDING=$((GAS_PER_COIN * 3))
ADDRESS_BALANCE_AMOUNT=$((TOTAL_FUNDING - GAS_RESERVE))
GENESIS_RUNTIME_CONFIG="/tmp/genesis-config.runtime.yaml"
mkdir -p "$DATA_DIR"
{
  cat "$GENESIS_CONFIG"
  echo "accounts:"
  while IFS= read -r alias; do
    printf '  - address: "%s"\n    gas_amounts: [%s]\n' \
      "${ADDR[$alias]}" "$TOTAL_FUNDING"
  done < <(jq -r '.accounts | keys_unsorted[]' "$ACCOUNTS_JSON")
} > "$GENESIS_RUNTIME_CONFIG"

# Snapshot mode needs short epochs so we can reach epoch >= 1 before sealing.
if [ "$MODE" = "snapshot" ]; then
  sed -i 's/^\([[:space:]]*\)epoch_duration_ms: .*/\1epoch_duration_ms: 30000/' "$GENESIS_RUNTIME_CONFIG"
  log "Snapshot mode: epoch_duration_ms overridden to 30000"
fi

log "Generating genesis from $GENESIS_RUNTIME_CONFIG (funding ${#ADDR[@]} accounts)"
sui genesis --from-config "$GENESIS_RUNTIME_CONFIG" --working-dir "$DATA_DIR" --with-faucet -f
# Genesis writes its own fullnode.yaml; overwriting it breaks faucet tx execution.

# ── 3. Start node ────────────────────────────────────────────────────────────
NODE_LOG="$DATA_DIR/node.log"
: >"$NODE_LOG"
START_ARGS=(--network.config "$DATA_DIR")
if [ "$MODE" != "test" ]; then
  START_ARGS+=(--with-faucet)
fi
start_node
ensure_rpc

# ── 3.5 Move surplus funds into address balance ──────────────────────────────
log "Moving surplus into address balance for ${#ADDR[@]} accounts (keeping $GAS_RESERVE MIST as owned gas each)..."
for alias in "${!ADDR[@]}"; do
  ensure_node_up
  sui client switch --address "${ADDR[$alias]}" >/dev/null
  sent=0
  for attempt in 1 2 3; do
    if sui client send-funds --to "${ADDR[$alias]}" --amount "$ADDRESS_BALANCE_AMOUNT" --gas-budget 100000000; then
      sent=1
      break
    fi
    log "WARN: send-funds failed for $alias (attempt $attempt/3); retrying in 3s..."
    ensure_node_up
    sleep 3
  done
  if [ "$sent" -ne 1 ]; then
    log "ERROR: send-funds failed for $alias after 3 attempts"
    tail -n 100 "$NODE_LOG" || true
    exit 1
  fi
done
sui client switch --address "${ADDR[ADMIN]}" >/dev/null

# ── 4. Install deps, deploy world, seed ──────────────────────────────────────
cd /app
export CI="${CI:-true}"

log "pnpm install..."
pnpm_install_args=(--frozen-lockfile)
[ -n "${PNPM_STORE_DIR:-}" ] && pnpm_install_args+=(--store-dir "$PNPM_STORE_DIR")
pnpm install "${pnpm_install_args[@]}"

log "Cleaning stale Move build artifacts..."
rm -rf contracts/*/build

log "Cleaning stale localnet deploy artifacts..."
rm -rf deployments/localnet

ensure_node_up
log "Deploying world to localnet..."
./scripts/deploy-world.sh localnet

log "Deploying currency to localnet..."
./scripts/deploy-currency.sh localnet

log "Seeding world ..."
./scripts/seed-world.sh localnet

fund_exchange_eve() {
  if [ -z "${ADDR[EXCHANGE]:-}" ]; then
    log "ERROR: EXCHANGE account missing from accounts.json"
    exit 1
  fi
  local amount="${EXCHANGE_EVE_AMOUNT:-10000000}"
  log "Transferring ${amount} EVE to EXCHANGE (${ADDR[EXCHANGE]})..."
  ENV=localnet RECIPIENT="${ADDR[EXCHANGE]}" AMOUNT="$amount" \
    pnpm --filter @evefrontier/world-sdk transfer:eve
}

# ── 5. Mode dispatch ─────────────────────────────────────────────────────────
case "$MODE" in
  test)
    log "Running integration tests..."
    ./scripts/run-integration-test.sh
    log "Integration tests passed."
    ;;
  snapshot)
    fund_exchange_eve
    wait_for_epoch 1
    log "Baking snapshot: stopping node cleanly..."
    stop_node final
    log "Staging world.json + accounts.json + test-resources.json for runtime host seeding..."
    mkdir -p "$STAGE_DIR"
    cp deployments/localnet/world.json "$STAGE_DIR/world.json"
    cp "$ACCOUNTS_JSON" "$STAGE_DIR/accounts.json"
    cp test-resources.json "$STAGE_DIR/test-resources.json"
    log "Swapping in the snapshot-image entrypoint..."
    mv /entrypoint-snapshot-image.sh /entrypoint.sh
    chmod +x /entrypoint.sh
    log "Snapshot baked. The container is now ready to be committed."
    ;;
  "")
    fund_exchange_eve
    log "Localnet ready at $RPC_URL with the world deployed. Leaving node running."
    wait "$NODE_PID"
    ;;
  *)
    log "ERROR: unknown mode '$MODE' (expected: test | snapshot | <empty>)"
    exit 1
    ;;
esac
