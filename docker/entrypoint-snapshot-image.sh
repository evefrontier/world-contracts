#!/usr/bin/env bash

set -euo pipefail

if [ -z "${POSTGRES_CONNECTION_STRING:-}" ]; then
    echo "ERROR: POSTGRES_CONNECTION_STRING is not set" >&2
    exit 1
fi

echo "========================"
echo "starting sui with indexer and graphql"
echo "========================"

# If /data/deployment is an empty host bind mount, it hides the baked layer; copy from a path that
# is never mounted so the same file appears on the host and in-container.
SEED=/opt/world-contracts/extracted-object-ids.json
if [ -f "$SEED" ]; then
    mkdir -p /data/deployment

    cp -f "$SEED" /data/deployment/extracted-object-ids.json
    echo "Seeded /data/deployment/extracted-object-ids.json from image (synced to host mount)."
fi

exec sui start --network.config /data/sui-localnet --with-faucet --with-indexer="$POSTGRES_CONNECTION_STRING" --with-graphql=0.0.0.0:9125
