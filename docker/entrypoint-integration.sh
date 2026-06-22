#!/usr/bin/env bash
# Integration / snapshot entrypoint for Dockerfile.integration.
#
# Brings up a DETERMINISTIC local Sui node: predefined, genesis-funded accounts
# (derived from the public test mnemonic in /genesis/accounts.json), deploys the
# world packages, then dispatches on the mode argument:
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
RPC_URL="http://127.0.0.1:9000"

log() { echo "[integration] $*"; }

# Graceful node shutdown so RocksDB flushes before the snapshot is committed.
stop_node() {
  local timeout="${SHUTDOWN_TIMEOUT:-60}"
  if kill -0 "$NODE_PID" 2>/dev/null; then
    kill "$NODE_PID" 2>/dev/null || true
    while kill -0 "$NODE_PID" 2>/dev/null && [ "$timeout" -gt 0 ]; do
      sleep 1
      timeout=$((timeout - 1))
    done
    if kill -0 "$NODE_PID" 2>/dev/null; then
      log "Node did not exit gracefully; forcing termination."
      kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    wait "$NODE_PID" 2>/dev/null || true
  fi
  trap - EXIT
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

MNEMONIC="$(jq -r '.mnemonic' "$ACCOUNTS_JSON")"
SCHEME="$(jq -r '.scheme' "$ACCOUNTS_JSON")"
if [ -z "$MNEMONIC" ] || [ "$MNEMONIC" = "null" ]; then
  log "ERROR: no mnemonic in $ACCOUNTS_JSON"; exit 1
fi

log "Importing predefined accounts from mnemonic (scheme: $SCHEME)..."
declare -A ADDR
while IFS=$'\t' read -r alias path; do
  sui keytool import "$MNEMONIC" "$SCHEME" "$path" --alias "$alias" >/dev/null 2>&1 \
    || { log "ERROR: failed to import $alias"; exit 1; }
  ADDR[$alias]="$(sui keytool export --key-identity "$alias" --json | jq -r '.key.suiAddress')"
  log "  $alias -> ${ADDR[$alias]}"
done < <(jq -r '.accounts[] | [.alias, .derivationPath] | @tsv' "$ACCOUNTS_JSON")

sui client switch --address "${ADDR[ADMIN]}" >/dev/null
export WORLD_ADMIN_ADDRESS="${ADDR[ADMIN]}"

# ── 2. Deterministic genesis ─────────────────────────────────────────────────
GAS_PER_COIN="${GENESIS_GAS_PER_COIN:-30000000000000000}"
GENESIS_RUNTIME_CONFIG="/tmp/genesis-config.runtime.yaml"
mkdir -p "$DATA_DIR"
{
  cat "$GENESIS_CONFIG"
  echo "accounts:"
  while IFS=$'\t' read -r alias _; do
    printf '  - address: "%s"\n    gas_amounts: [%s, %s, %s]\n' \
      "${ADDR[$alias]}" "$GAS_PER_COIN" "$GAS_PER_COIN" "$GAS_PER_COIN"
  done < <(jq -r '.accounts[] | [.alias, .derivationPath] | @tsv' "$ACCOUNTS_JSON")
} > "$GENESIS_RUNTIME_CONFIG"

log "Generating genesis from $GENESIS_RUNTIME_CONFIG (funding ${#ADDR[@]} accounts)"
sui genesis --from-config "$GENESIS_RUNTIME_CONFIG" --working-dir "$DATA_DIR" --with-faucet -f
cp /fullnode.yaml "$DATA_DIR/fullnode.yaml"

# ── 3. Start node ────────────────────────────────────────────────────────────
log "Starting local Sui node..."
sui start --network.config "$DATA_DIR" --with-faucet &
NODE_PID=$!
trap 'kill "$NODE_PID" 2>/dev/null || true' EXIT

log "Waiting for RPC at $RPC_URL ..."
for i in $(seq 1 60); do
  curl -sf -X POST "$RPC_URL" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"rpc.discover","id":1}' >/dev/null 2>&1 && break
  if [ "$i" -eq 60 ]; then log "ERROR: RPC did not become ready"; exit 1; fi
  sleep 1
done
sleep 2
log "RPC ready."

# ── 4. Install deps, deploy world, seed ──────────────────────────────────────
cd /app
export CI="${CI:-true}"

log "pnpm install..."
pnpm install --frozen-lockfile

log "Deploying world to localnet..."
./scripts/deploy-world.sh localnet

log "Seeding world (no-op until seed steps are added to seed-world.sh)..."
./scripts/seed-world.sh localnet

# ── 5. Mode dispatch ─────────────────────────────────────────────────────────
case "$MODE" in
  test)
    log "Running integration tests..."
    ./scripts/run-integration-test.sh
    log "Integration tests passed."
    ;;
  snapshot)
    log "Baking snapshot: stopping node cleanly..."
    stop_node
    log "Staging world.json for runtime host seeding..."
    mkdir -p /opt/world-contracts
    cp deployments/localnet/world.json /opt/world-contracts/world.json
    log "Swapping in the snapshot-image entrypoint..."
    mv /entrypoint-snapshot-image.sh /entrypoint.sh
    chmod +x /entrypoint.sh
    log "Snapshot baked. The container is now ready to be committed."
    ;;
  "")
    log "Localnet ready at $RPC_URL with the world deployed. Leaving node running."
    wait "$NODE_PID"
    ;;
  *)
    log "ERROR: unknown mode '$MODE' (expected: test | snapshot | <empty>)"
    exit 1
    ;;
esac
