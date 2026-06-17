#!/usr/bin/env bash
# MVR (Move Registry) constants and helpers. 

# @mvr/metadata (PackageInfo) — lives on every network.
MVR_METADATA_TESTNET="0xb96f44d08ae214887cae08d8ae061bbf6f0908b1bfccb710eea277f45150b9f4"
MVR_METADATA_MAINNET="0xc88768f8b26581a8ee1bf71e6a6ec0f93d4cc6460ebb66a31b94d64de8105c98"

# @mvr/core (name registry) + its shared registry object — mainnet only.
MVR_CORE_MAINNET="0xbb97fa5af2504cc944a8df78dcb5c8b72c3673ca4ba8e4969a98188bf745ee54"
MVR_REGISTRY="0x0e5d473a055b6b7d014af557a13ad9075157fdc19b6d51562a18511afd397727"

# SuiNS namespace these names live under.
MVR_NAMESPACE="@evefrontier"

# @mvr/metadata package address for the network an env deploys to.
mvr_metadata_pkg() {
    case "$(get_network "$1")" in
        testnet) echo "$MVR_METADATA_TESTNET" ;;
        mainnet) echo "$MVR_METADATA_MAINNET" ;;
        *) echo "mvr_metadata_pkg: no MVR on network for env '$1'" >&2; exit 1 ;;
    esac
}

# Per-package, per-env MVR name: world-<pkg>-<env>; live drops the suffix.
mvr_name() {
    local pkg=$1 env=$2
    if [[ "$env" == "live" ]]; then
        echo "$MVR_NAMESPACE/world-$pkg"
    else
        echo "$MVR_NAMESPACE/world-$pkg-$env"
    fi
}

# The testnet chain-id the mainnet name record points its testnet network entry at.
MVR_TESTNET_CHAIN_ID="4c78adac"
