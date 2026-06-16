#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="/data/sui-localnet"
SEED_SRC="/opt/world-contracts/world.json"   # baked at bake time, never mounted
SEED_DST_DIR="/data/deployment"               # host bind mount target

if [ -z "${POSTGRES_CONNECTION_STRING:-}" ]; then
    echo "ERROR: POSTGRES_CONNECTION_STRING is not set" >&2
    exit 1
fi

if [ -f "$SEED_SRC" ]; then
    mkdir -p "$SEED_DST_DIR"
    cp -f "$SEED_SRC" "$SEED_DST_DIR/world.json"
    echo "Seeded $SEED_DST_DIR/world.json from the image (synced to the host mount)."
else
    echo "WARN: $SEED_SRC not found; skipping world.json seed." >&2
fi

echo "========================================"
echo "Starting Sui localnet with indexer + GraphQL"
echo "  RPC      : 0.0.0.0:9000"
echo "  GraphQL  : 0.0.0.0:9125"
echo "========================================"

exec sui start \
    --network.config "$DATA_DIR" \
    --with-faucet \
    --with-indexer="$POSTGRES_CONNECTION_STRING" \
    --with-graphql=0.0.0.0:9125
