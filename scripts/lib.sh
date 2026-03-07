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
        localnet|testnet|mainnet|devnet|testnet_internal|testnet_utopia|testnet_stillness) echo "$env" ;;
        *) echo "Usage: $0 [localnet|testnet|mainnet|devnet|testnet_internal|testnet_utopia|testnet_stillness]" >&2; exit 1 ;;
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

# Deployment folder (testnet_* variants all use deployments/testnet).
get_deploy_dir() {
    case "$1" in
        testnet_internal|testnet_utopia|testnet_stillness) echo "testnet" ;;
        *) echo "$1" ;;
    esac
}

# Sui client env for publish (testnet_* variants use same RPC as testnet).
sui_client_env() {
    case "$1" in
        testnet_internal|testnet_utopia|testnet_stillness) echo "testnet" ;;
        *) echo "$1" ;;
    esac
}

publish() {
    local pkg=$1
    local out_file=$2
    local env=$3
    local localnet_pubfile=${4:-}
    local sui_env
    sui_env=$(sui_client_env "$env")
    local tmp
    tmp=$(mktemp)
    trap "rm -f $tmp" RETURN

    sui client switch --env "$sui_env"

    if [[ "$env" == "localnet" ]]; then
        if [[ -n "$localnet_pubfile" ]]; then
            # Path is relative to contracts/$pkg (same as test-publish cwd); check from there.
            if ! (cd "contracts/$pkg" && [[ -f "$localnet_pubfile" && -r "$localnet_pubfile" ]]); then
                echo "Error: localnet pubfile not found or not readable: $localnet_pubfile (from contracts/$pkg)" >&2
                exit 1
            fi
            (cd "contracts/$pkg" && sui client test-publish --build-env testnet --pubfile-path "$localnet_pubfile" --json) > "$tmp" 2>&1 || true
        else
            (cd "contracts/$pkg" && sui client test-publish --build-env testnet --json) > "$tmp" 2>&1 || true
        fi
    else
        (cd "contracts/$pkg" && sui client publish -e "$sui_env" --json) > "$tmp" 2>&1 || true
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
