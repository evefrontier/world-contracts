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
        *) echo "get_env: unknown env '$env' (want localnet|dev|test|uat|live)" >&2; exit 1 ;;
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

get_rpc() {
    case "$1" in
        localnet)      echo "http://127.0.0.1:9000" ;;
        dev|test|uat)  echo "https://fullnode.testnet.sui.io:443" ;;
        live)          echo "https://fullnode.mainnet.sui.io:443" ;;
        *) echo "get_rpc: unknown env '$1'" >&2; exit 1 ;;
    esac
}

# Create an empty Sui client config if none exists, so keytool/client can write.
# Needed when running without the image entrypoint (which does its own init).
sui_init_config() {
    local env=$1 rpc=$2 cfg="$HOME/.sui/sui_config"
    [[ -f "$cfg/client.yaml" ]] && return 0
    mkdir -p "$cfg"
    cat > "$cfg/client.yaml" <<EOF
---
keystore:
  File: $cfg/sui.keystore
envs:
  - alias: $env
    rpc: "$rpc"
    ws: ~
    basic_auth: ~
active_env: $env
active_address: ~
EOF
    echo "[]" > "$cfg/sui.keystore"
}

# Import a private key into the keystore (idempotent), print its address.
import_key() {
    local key=$1 out rc
    [[ -z "$key" ]] && return 0
    set +e
    out=$(sui keytool import "$key" "${KEY_SCHEME:-ed25519}" 2>&1)
    rc=$?
    set -e
    if [[ $rc -ne 0 ]] && ! grep -qi "already exists" <<<"$out"; then
        echo "import_key: $out" >&2
        return 1
    fi
    grep -oE '0x[a-fA-F0-9]{64}' <<<"$out" | head -1
}

# publish builds for the active client env and writes [published.<active-env>],
# so the client env name must equal the Move env name (dev/test/uat).
ensure_client_env() {
    local env=$1 rpc=$2
    sui client switch --env "$env" >/dev/null 2>&1 \
        || sui client new-env --alias "$env" --rpc "$rpc" >/dev/null
    sui client switch --env "$env" >/dev/null
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

# Run `sui <cmd> --json` from contracts/$pkg, capture output, fail on non-JSON.
# Args: pkg env action out_file cmd...
_run_pkg_cmd() {
    local pkg=$1 env=$2 action=$3 out_file=$4
    shift 4
    local tmp tmp_err
    tmp=$(mktemp)
    tmp_err=$(mktemp)

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
        rm -f -- "$tmp" "$tmp_err"
        exit 1
    fi

    cp "$tmp" "$out_file"
    rm -f -- "$tmp" "$tmp_err"
    echo "$action $pkg -> $out_file"
}

# localnet test-publishes into the shared ephemeral $pubfile; named envs publish
# against the active client env, maintaining the committed Published.toml.
publish() {
    local pkg=$1 env=$2 pubfile=$3 out_file=$4
    if [[ "$env" == "localnet" ]]; then
        _run_pkg_cmd "$pkg" "$env" "Publish" "$out_file" \
            sui client test-publish --build-env testnet --pubfile-path "$pubfile"
    else
        _run_pkg_cmd "$pkg" "$env" "Publish" "$out_file" \
            sui client publish
    fi
}

# Upgrade reuses the UpgradeCap recorded in the committed Published.toml.
upgrade() {
    local pkg=$1 env=$2 out_file=$3
    if [[ "$env" == "localnet" ]]; then
        echo "ERROR: upgrade is not supported for localnet (ephemeral test-publish)." >&2
        exit 1
    fi
    _run_pkg_cmd "$pkg" "$env" "Upgrade" "$out_file" \
        sui client upgrade
}
