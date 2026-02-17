#!/usr/bin/env bash
# Shared deploy helpers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

setup() {
    cd "$REPO_ROOT"
    [ -f .env ] && set -a && source .env && set +a
}

get_env() {
    local env="${1:-${SUI_NETWORK:-localnet}}"
    [[ "$env" == "local" ]] && env="localnet"
    case "$env" in
        localnet|testnet|mainnet|devnet) echo "$env" ;;
        *) echo "Usage: $0 [localnet|testnet|mainnet|devnet]" >&2; exit 1 ;;
    esac
}

# Start logging to deployments/$env/deploy.log. Call after get_env and mkdir.
start_logging() {
    local env=$1
    local name=$2
    LOG="deployments/$env/deploy.log"
    {
        echo ""
        echo "=== $(date -Iseconds 2>/dev/null || date) $name $env ==="
    } >> "$LOG"
    exec 1> >(tee -a "$LOG") 2>&1
}

publish() {
    local pkg=$1
    local out_file=$2
    local env=$3
    local tmp
    tmp=$(mktemp)
    trap "rm -f $tmp" RETURN

    sui client switch --env "$env"

    if [[ "$env" == "localnet" ]]; then
        (cd "contracts/$pkg" && sui client test-publish --build-env testnet --json) > "$tmp" 2>&1 || true
    else
        (cd "contracts/$pkg" && sui client publish --json) > "$tmp" 2>&1 || true
    fi

    pnpm exec tsx ts-scripts/utils/extract-json.ts "$tmp" > "$out_file" || true

    log="${LOG:-deployments/$env/deploy.log}"
    {
        echo ""
        echo "--- Publish output ---"
        cat "$tmp"
    } >> "$log"

    if [[ ! -s "$out_file" ]]; then
        echo "" >&2
        echo "=== Publish failed. Raw output ===" >&2
        cat "$tmp" >&2
        exit 1
    fi
}
