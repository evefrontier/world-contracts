#!/usr/bin/env bash
# Shared deploy helpers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

setup() {
    cd "$REPO_ROOT"
    if [ -f .env ]; then
        set -a
        source .env
        set +a
    fi
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

# Publish one package to the current network and save the raw --json output.
# Args: pkg env pubfile out_file
#   pkg      package dir name under contracts/ (e.g. core)
#   env      target env (localnet uses ephemeral test-publish; others use publish)
#   pubfile  absolute path to a SHARED pubfile; all packages read/write the same
#            file so local deps (character -> core) resolve their published ids
#   out_file path to write the raw publish JSON to
publish() {
    local pkg=$1 env=$2 pubfile=$3 out_file=$4
    local tmp tmp_err
    tmp=$(mktemp)
    tmp_err=$(mktemp)
    trap 'rm -f -- "$tmp" "$tmp_err"' RETURN

    # JSON goes to stdout; build progress goes to stderr. Do not merge them.
    if [[ "$env" == "localnet" ]]; then
        (cd "contracts/$pkg" && sui client test-publish --build-env testnet --pubfile-path "$pubfile" --json) > "$tmp" 2> "$tmp_err" || true
    else
        (cd "contracts/$pkg" && sui client publish --json) > "$tmp" 2> "$tmp_err" || true
    fi

    {
        echo ""
        echo "--- Publish $pkg output ---"
        cat "$tmp"
        if [[ -s "$tmp_err" ]]; then
            echo "--- Publish $pkg stderr ---"
            cat "$tmp_err"
        fi
    } >> "${LOG:-deployments/$env/deploy.log}"

    # On dependency/build errors sui prints a plain message to stdout, not JSON.
    if [[ "$(head -c1 "$tmp")" != "{" ]]; then
        echo "ERROR: publish '$pkg' failed:" >&2
        cat "$tmp" "$tmp_err" >&2
        exit 1
    fi

    cp "$tmp" "$out_file"
    echo "Published $pkg -> $out_file"
}
