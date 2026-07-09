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
# is never mounted so the same files appear on the host and in-container.
mkdir -p /data/deployment

SEED=/opt/world-contracts/extracted-object-ids.json
if [ -f "$SEED" ]; then
    cp -f "$SEED" /data/deployment/extracted-object-ids.json
    echo "Seeded /data/deployment/extracted-object-ids.json from image (synced to host mount)."
fi

# The well-known test keypairs + addresses for the baked accounts (EF-17566).
ACCOUNTS_SEED=/opt/world-contracts/accounts.json
if [ -f "$ACCOUNTS_SEED" ]; then
    cp -f "$ACCOUNTS_SEED" /data/deployment/accounts.json
    echo "Seeded /data/deployment/accounts.json from image (synced to host mount)."
fi

exec sui start --network.config /data/sui-localnet --with-faucet --with-indexer="$POSTGRES_CONNECTION_STRING" --with-graphql=0.0.0.0:9125
