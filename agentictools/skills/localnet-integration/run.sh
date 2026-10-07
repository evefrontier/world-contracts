#!/usr/bin/env bash
# Localnet + integration-test helper for agents and humans.
#
#   run.sh test          build image, fresh localnet, deploy, run SDK integration suite, exit
#   run.sh up            fresh localnet with world deployed, left running (detached)
#   run.sh host-test     run the SDK integration suite on the host against `up`
#   run.sh logs          follow the `up` container's logs
#   run.sh down          stop and remove the `up` container
#   run.sh snapshot-up   pre-baked snapshot chain (+ indexer/GraphQL) via compose
#   run.sh snapshot-down stop the snapshot stack
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
IMAGE="${IMAGE:-world-integration}"
CONTAINER="${CONTAINER:-world-localnet}"
RPC_URL="http://127.0.0.1:9000"
ACCOUNTS="$ROOT/docker/genesis/accounts.json"
SNAPSHOT_COMPOSE="$ROOT/docker/docker-compose-snapshot-image.yml"

log() { echo "[localnet] $*"; }
die() { echo "[localnet] ERROR: $*" >&2; exit 1; }

preflight() {
  command -v docker >/dev/null || die "docker not installed"
  docker info >/dev/null 2>&1 || die "docker daemon not running"
}

port_free() {
  if lsof -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; then
    die "port $1 already in use (another localnet? try: run.sh down / snapshot-down)"
  fi
}

build() {
  log "Building $IMAGE from docker/Dockerfile.integration..."
  docker build -f "$ROOT/docker/Dockerfile.integration" -t "$IMAGE" "$ROOT"
}

wait_world() {
  log "Waiting for deploy to finish (deployments/localnet/world.json + RPC)..."
  for _ in $(seq 1 300); do
    if ! docker ps -q -f "name=^${CONTAINER}$" | grep -q .; then
      docker logs --tail 100 "$CONTAINER" 2>&1 || true
      die "container exited before localnet was ready"
    fi
    if docker logs "$CONTAINER" 2>&1 | grep -q "Localnet ready at"; then
      log "Localnet ready at $RPC_URL (faucet :9123)."
      return 0
    fi
    sleep 2
  done
  die "timed out waiting for localnet"
}

account() { jq -r ".accounts.$1.$2" "$ACCOUNTS"; }

cmd="${1:-}"
case "$cmd" in
  test)
    preflight; build
    docker run --rm -v "$ROOT:/app" -w /app -e CI=true "$IMAGE" test
    ;;
  up)
    preflight; port_free 9000; port_free 9123; build
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER" -v "$ROOT:/app" -w /app -e CI=true \
      -p 9000:9000 -p 9123:9123 "$IMAGE" >/dev/null
    wait_world
    ;;
  host-test)
    [ -f "$ROOT/deployments/localnet/world.json" ] || die "no deployments/localnet/world.json — run: run.sh up"
    cd "$ROOT"
    # The container ran `pnpm install` into the mounted repo with Linux binaries;
    # reinstall so host-native deps (esbuild, biome) match this machine.
    pnpm install --frozen-lockfile >/dev/null
    SUI_PRIVATE_KEY="$(account ADMIN privateKey)" \
    WORLD_ADMIN_ADDRESS="$(account ADMIN address)" \
      pnpm --filter @evefrontier/world-sdk test:integration "${@:2}"
    ;;
  logs)
    docker logs -f "$CONTAINER"
    ;;
  down)
    docker rm -f "$CONTAINER" >/dev/null 2>&1 && log "Stopped $CONTAINER." || log "Nothing to stop."
    ;;
  snapshot-up)
    preflight; port_free 9000
    docker compose -f "$SNAPSHOT_COMPOSE" up -d --wait
    log "Snapshot chain up. Artifacts: deployments/localnet-snapshot/ · RPC :9000 · faucet :9123 · GraphQL :9125"
    ;;
  snapshot-down)
    docker compose -f "$SNAPSHOT_COMPOSE" down -v
    ;;
  *)
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
