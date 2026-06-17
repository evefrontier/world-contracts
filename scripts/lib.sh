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
    local env="${1:-${DEPLOY_ENV:-${SUI_NETWORK:-localnet}}}"
    [[ "$env" == "local" ]] && env="localnet"
    case "$env" in
        localnet|dev|test|uat|live) echo "$env" ;;
        *) echo "Usage: $0 [localnet|dev|test|uat|live] [publish|upgrade]" >&2; exit 1 ;;
    esac
}

get_network() {
    case "$1" in
        localnet)      echo "localnet" ;;
        dev|test|uat)  echo "testnet" ;;
        live)          echo "mainnet" ;;
        *) echo "get_network: unknown env '$1'" >&2; exit 1 ;;
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

# Run a publish/upgrade command for one package, capturing the raw --json output,
# logging both streams, and failing loudly on non-JSON (build/dep) errors.
# Args: pkg env action out_file cmd...
#   pkg      package dir name under contracts/ (e.g. core)
#   env      deployment env (for logging/labels)
#   action   human label for logs/errors (e.g. "Publish", "Upgrade")
#   out_file path to write the raw JSON to
#   cmd...   the sui invocation, run from contracts/$pkg
_run_pkg_cmd() {
    local pkg=$1 env=$2 action=$3 out_file=$4
    shift 4
    local tmp tmp_err
    tmp=$(mktemp)
    tmp_err=$(mktemp)
    trap 'rm -f -- "$tmp" "$tmp_err"' RETURN

    # JSON goes to stdout; build progress goes to stderr. Do not merge them.
    (cd "contracts/$pkg" && "$@" --json) > "$tmp" 2> "$tmp_err" || true

    {
        echo ""
        echo "--- $action $pkg output ---"
        cat "$tmp"
        if [[ -s "$tmp_err" ]]; then
            echo "--- $action $pkg stderr ---"
            cat "$tmp_err"
        fi
    } >> "${LOG:-deployments/$env/deploy.log}"

    # On dependency/build errors sui prints a plain message to stdout, not JSON.
    if [[ "$(head -c1 "$tmp")" != "{" ]]; then
        echo "ERROR: $action '$pkg' failed:" >&2
        cat "$tmp" "$tmp_err" >&2
        exit 1
    fi

    cp "$tmp" "$out_file"
    echo "$action $pkg -> $out_file"
}

# Publish one package and save the raw --json output.
# Args: pkg env pubfile out_file
#   env      deployment env. localnet uses ephemeral test-publish into the shared
#            pubfile; named envs (dev/test/uat/live) use `sui client publish -e <env>`,
#            which maintains the COMMITTED contracts/<pkg>/Published.toml.
#   pubfile  absolute path to a SHARED pubfile (localnet only); all packages
#            read/write it so local deps (character -> core) resolve published ids.
publish() {
    local pkg=$1 env=$2 pubfile=$3 out_file=$4
    if [[ "$env" == "localnet" ]]; then
        _run_pkg_cmd "$pkg" "$env" "Publish" "$out_file" \
            sui client test-publish --build-env testnet --pubfile-path "$pubfile"
    else
        _run_pkg_cmd "$pkg" "$env" "Publish" "$out_file" \
            sui client publish -e "$env"
    fi
}

# Upgrade one package on a named env, reusing the UpgradeCap recorded in the
# committed contracts/<pkg>/Published.toml [published.<env>]. Testnet-only
# Args: pkg env out_file
upgrade() {
    local pkg=$1 env=$2 out_file=$3
    if [[ "$env" == "localnet" ]]; then
        echo "ERROR: upgrade is not supported for localnet (ephemeral test-publish)." >&2
        exit 1
    fi
    _run_pkg_cmd "$pkg" "$env" "Upgrade" "$out_file" \
        sui client upgrade -e "$env"
}
