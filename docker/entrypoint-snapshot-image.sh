#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="/data/sui-localnet"
SEED_SRC_DIR="/opt/world-contracts"   # baked at bake time, never mounted
SEED_DST_DIR="/data/deployment"       # host bind mount target
SEED_FILES=(world.json accounts.json test-resources.json)

if [ -z "${POSTGRES_CONNECTION_STRING:-}" ]; then
    echo "ERROR: POSTGRES_CONNECTION_STRING is not set" >&2
    exit 1
fi

mkdir -p "$SEED_DST_DIR"
for file in "${SEED_FILES[@]}"; do
    if [ -f "$SEED_SRC_DIR/$file" ]; then
        cp -f "$SEED_SRC_DIR/$file" "$SEED_DST_DIR/$file"
        echo "Seeded $SEED_DST_DIR/$file from the image (synced to the host mount)."
    else
        echo "WARN: $SEED_SRC_DIR/$file not found; skipping." >&2
    fi
done

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
