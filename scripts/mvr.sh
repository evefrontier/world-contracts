#!/usr/bin/env bash
# MVR (Move Registry) operations, per package per env.
#
#   mvr.sh package-info      <env> <pkg>
#   mvr.sh set-network       <env> <pkg>
#   mvr.sh git-version       <env> <pkg> <ver> <commit>
#   mvr.sh set-appcap        <env> <pkg> <appCapId>
#   mvr.sh bootstrap-appcap  <env> <pkg> [recipient]
#
# bootstrap-appcap is a one-time, manual step per new (pkg, env) pair
# It mints a permanent SuiNS subname, so run it deliberately with the
# @evefrontier-owning mainnet key, not as part of the automated deploy.
# The AppCap goes to [recipient], or to the signer when omitted.
#
# Txs are signed by the active CLI address, or by AWS KMS when SUINS_KMS_KEY_ID
# is set (e.g. SUINS_KMS_KEY_ID=$APPCAP_KMS_KEY_ID for the AppCap key).
#
# Object ids are read from / written to the committed deployments/<env>/world.json.
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/mvr-lib.sh"

GIT_REPO="https://github.com/evefrontier/world-contracts"

usage() {
    echo "Usage: $0 <package-info|set-network|git-version|set-appcap|bootstrap-appcap> <env> <pkg> [args]" >&2
    exit 1
}

# Read packages.<pkg>.<field> from the env's world.json (written by build-manifest.ts
# during deploy-world.sh, before any mvr.sh call). Fields: publishedAt, upgradeCap, ...
pkg_field() {
    jq -r --arg p "$2" --arg f "$3" '.packages[$p][$f] // empty' "deployments/$1/world.json"
}

# Read/write mvr.<pkg>.<field> in the env's world.json (read-modify-write, preserves the rest).
mvr_get() {
    jq -r --arg p "$2" --arg f "$3" '.mvr[$p][$f] // empty' "deployments/$1/world.json"
}

mvr_set() {
    local world="deployments/$1/world.json" pkg=$2 field=$3 value=$4
    local tmp
    tmp=$(mktemp)
    jq --arg p "$pkg" --arg f "$field" --arg v "$value" \
        '.mvr[$p] = (.mvr[$p] // {}) + {($f): $v}' "$world" > "$tmp" && mv "$tmp" "$world"
}

# Run a ptb, capture --json, fail on non-JSON; writes to $out.
run_ptb() {
    local label=$1 out=$2
    shift 2
    local tmp tmp_err
    tmp=$(mktemp)
    tmp_err=$(mktemp)
    sui_tx ptb "$@" > "$tmp" 2> "$tmp_err" || true
    if [[ "$(head -c1 "$tmp")" != "{" && "$(head -c1 "$tmp")" != "[" ]]; then
        echo "ERROR: $label failed:" >&2
        cat "$tmp" "$tmp_err" >&2
        rm -f -- "$tmp" "$tmp_err"
        exit 1
    fi
    rm -f -- "$tmp_err"
    mv "$tmp" "$out"
    echo "$label -> $out"
}

# Create the PackageInfo on the target network (owned by deployer); record its id.
cmd_package_info() {
    local env=$1 pkg=$2
    local meta name cap out
    meta=$(mvr_metadata_pkg "$env")
    name=$(mvr_name "$pkg" "$env")
    cap=$(pkg_field "$env" "$pkg" upgradeCap)
    out="deployments/$env/$pkg.package-info.json"

    ensure_client_env "$env" "$(get_rpc "$env")"
    run_ptb "PackageInfo $pkg" "$out" \
        --move-call "$meta::package_info::new" "@$cap" --assign pi \
        --move-call "$meta::display::default" "\"$pkg-$env\"" --assign display \
        --move-call "$meta::package_info::set_display" pi display \
        --move-call "$meta::package_info::set_metadata" pi "\"default\"" "\"$name\"" \
        --move-call sui::tx_context::sender --assign sender \
        --move-call "$meta::package_info::transfer" pi sender

    local pi_id
    pi_id=$(jq -r '.objectChanges[] | select(.type=="created" and (.objectType|endswith("::package_info::PackageInfo"))) | .objectId' "$out" | head -1)
    [[ -z "$pi_id" ]] && { echo "ERROR: no PackageInfo created in $out" >&2; exit 1; }

    mvr_set "$env" "$pkg" name "$name"
    mvr_set "$env" "$pkg" packageInfo "$pi_id"
    echo "PackageInfo $pkg ($name) = $pi_id"
}

# Repoint the mainnet name at the target-network PackageInfo + address.
# AppCap key, MAINNET. Deploy mode only (new lineage).
cmd_set_network() {
    local env=$1 pkg=$2
    local pi_id pkg_addr app_cap
    pi_id=$(mvr_get "$env" "$pkg" packageInfo)
    pkg_addr=$(pkg_field "$env" "$pkg" publishedAt)
    app_cap=$(mvr_get "$env" "$pkg" appCap)
    [[ -z "$pi_id"   ]] && { echo "ERROR: no packageInfo for $pkg/$env — run package-info first" >&2; exit 1; }
    [[ -z "$app_cap" ]] && { echo "ERROR: no appCap for $pkg/$env — run set-appcap (manual bootstrap)" >&2; exit 1; }

    ensure_client_env mainnet "$(get_rpc live)"

    sui_tx ptb \
        --move-call "$MVR_CORE_MAINNET::move_registry::unset_network" \
            "@$MVR_REGISTRY" "@$app_cap" "\"$MVR_TESTNET_CHAIN_ID\"" \
        || echo "unset_network: no existing mapping for $pkg (first deploy)"
    sui_tx ptb \
        --move-call 0x1::option::some "<0x2::object::ID>" "@$pi_id" --assign pinfo \
        --move-call 0x1::option::some "<address>" "@$pkg_addr" --assign pid \
        --move-call 0x1::option::none "<0x2::object::ID>" --assign null \
        --move-call "$MVR_CORE_MAINNET::app_info::new" pinfo pid null --assign appinfo \
        --move-call "$MVR_CORE_MAINNET::move_registry::set_network" \
            "@$MVR_REGISTRY" "@$app_cap" "\"$MVR_TESTNET_CHAIN_ID\"" appinfo
    echo "set_network $pkg -> packageInfo $pi_id @ $MVR_TESTNET_CHAIN_ID"
}

# Record source metadata for a version on the target network. Optional, repeatable.
cmd_git_version() {
    local env=$1 pkg=$2 version=$3 commit=$4
    local meta pi_id
    [[ -z "$version" || -z "$commit" ]] && usage
    meta=$(mvr_metadata_pkg "$env")
    pi_id=$(mvr_get "$env" "$pkg" packageInfo)
    [[ -z "$pi_id" ]] && { echo "ERROR: no packageInfo for $pkg/$env — run package-info first" >&2; exit 1; }

    ensure_client_env "$env" "$(get_rpc "$env")"
    sui_tx ptb \
        --move-call "$meta::git::new" "\"$GIT_REPO\"" "\"contracts/$pkg\"" "\"$commit\"" --assign git \
        --move-call "$meta::package_info::set_git_versioning" "@$pi_id" "$version" git
    echo "set_git_versioning $pkg v$version @ $commit"
}

# One-time bootstrap: register world-<pkg>-<env> on MAINNET and send the AppCap
# to the recipient (default: the signer).
cmd_bootstrap_appcap() {
    local env=$1 pkg=$2 recipient=${3:-}
    local name out app_cap to
    [[ "$env" == "localnet" ]] && {
        echo "ERROR: bootstrap-appcap is mainnet-only — not for localnet" >&2
        exit 1
    }
    if [[ -n "$recipient" ]]; then
        [[ "$recipient" =~ ^0x[a-fA-F0-9]{64}$ ]] || { echo "ERROR: bad recipient '$recipient'" >&2; exit 1; }
        to="@$recipient"
    else
        to=sender
    fi
    name=$(mvr_name "$pkg" "$env")
    # register() takes the app label only; the @evefrontier parent is MVR_SUINS_PARENT.
    label="${name#*/}"
    out="deployments/$env/$pkg.appcap.json"

    ensure_client_env mainnet "$(get_rpc live)"
    run_ptb "register $name" "$out" \
        --move-call "$MVR_CORE_MAINNET::move_registry::register" \
            "@$MVR_REGISTRY" "@$MVR_SUINS_PARENT" "\"$label\"" "@0x6" --assign appcap \
        --move-call sui::tx_context::sender --assign sender \
        --transfer-objects "[appcap]" "$to"

    app_cap=$(jq -r '.objectChanges[] | select(.type=="created" and (.objectType|contains("AppCap"))) | .objectId' "$out" | head -1)
    [[ -z "$app_cap" ]] && { echo "ERROR: no AppCap created in $out" >&2; exit 1; }

    mvr_set "$env" "$pkg" appCap "$app_cap"
    echo "bootstrap-appcap $pkg/$env: registered '$name', appCap = $app_cap -> ${recipient:-signer}"
}

setup
[[ $# -lt 3 ]] && usage
SUB=$1
ENV=$(get_env "$2")
PKG=$3
shift 3
require_world_json "$ENV"

case "$SUB" in
    package-info) cmd_package_info "$ENV" "$PKG" ;;
    set-network)  cmd_set_network  "$ENV" "$PKG" ;;
    git-version)  cmd_git_version  "$ENV" "$PKG" "${1:-}" "${2:-}" ;;
    set-appcap)      [[ -z "${1:-}" ]] && usage; mvr_set "$ENV" "$PKG" appCap "$1"; echo "appCap $PKG/$ENV = $1" ;;
    bootstrap-appcap) cmd_bootstrap_appcap "$ENV" "$PKG" "${1:-}" ;;
    *) usage ;;
esac
