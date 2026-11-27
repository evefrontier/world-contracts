#!/usr/bin/env bash
# Shared helpers for ci-deploy.sh / ci-deploy-currency.sh (sourced, not executed).

# Run a step, or just print it under DRY_RUN=1.
run() {
    if [[ "${DRY_RUN:-}" == "1" ]]; then echo "DRY_RUN: $*"; else "$@"; fi
}

# Resolve the deployer and AppCap signers: an AWS KMS key (*_KMS_KEY_ID) or a
# private key (*_KEY). The AppCap signer defaults to the deployer.
# Sets: DEPLOYER_ADDR, APPCAP_ADDR. Leaves the deployer as the active signer.
ci_bootstrap_keys() {
    : "${TARGET_ENV:?}" "${NET:?}"

    sui_init_config "$NET" "$(get_rpc "$TARGET_ENV")"
    if [[ -n "${DEPLOYER_KMS_KEY_ID:-}" ]]; then
        DEPLOYER_ADDR=$(kms_signer address "$DEPLOYER_KMS_KEY_ID")
    else
        : "${DEPLOYER_KEY:?set DEPLOYER_KEY or DEPLOYER_KMS_KEY_ID}"
        DEPLOYER_ADDR=$(import_key "$DEPLOYER_KEY")
        export SUI_PRIVATE_KEY="$DEPLOYER_KEY"
    fi
    [[ -z "$DEPLOYER_ADDR" ]] && { echo "ERROR: could not resolve deployer address" >&2; exit 1; }

    APPCAP_ADDR="$DEPLOYER_ADDR"
    if [[ -n "${APPCAP_KMS_KEY_ID:-}" ]]; then
        APPCAP_ADDR=$(kms_signer address "$APPCAP_KMS_KEY_ID")
    elif [[ -n "${APPCAP_KEY:-}" ]]; then
        APPCAP_ADDR=$(import_key "$APPCAP_KEY")
    else
        APPCAP_KMS_KEY_ID=${DEPLOYER_KMS_KEY_ID:-}
    fi
    echo "deployer: $DEPLOYER_ADDR${DEPLOYER_KMS_KEY_ID:+ (KMS)}"
    echo "appcap:   $APPCAP_ADDR${APPCAP_KMS_KEY_ID:+ (KMS)}"
    use_signer deployer
}

# Sign the following sui txs with the deployer or the AppCap key.
use_signer() {
    local kms addr
    case "$1" in
        deployer) kms=${DEPLOYER_KMS_KEY_ID:-}; addr=$DEPLOYER_ADDR ;;
        appcap)   kms=${APPCAP_KMS_KEY_ID:-};   addr=$APPCAP_ADDR ;;
        *) echo "use_signer: unknown signer '$1'" >&2; exit 1 ;;
    esac
    export SUINS_KMS_KEY_ID="$kms"
    if [[ -z "$kms" ]]; then
        sui client switch --address "$addr" >/dev/null
    fi
}

# Copy Published.toml for each pkg + world.json into deployments/$TARGET_ENV/records.
# Args: package names...
ci_export_artifacts() {
    local dir="deployments/$TARGET_ENV/records" pkg
    rm -rf "$dir"
    for pkg in "$@"; do
        mkdir -p "$dir/contracts/$pkg"
        cp "contracts/$pkg/Published.toml" "$dir/contracts/$pkg/Published.toml"
    done
    cp "deployments/$TARGET_ENV/world.json" "$dir/world.json"
}

# Clear [published.<env>] so a fresh publish can proceed.
# Args: package names...
ci_clear_published() {
    local pkg
    for pkg in "$@"; do
        run pnpm exec tsx ts-scripts/clear-published.ts \
            "contracts/$pkg/Published.toml" "$TARGET_ENV"
    done
}

ci_require_appcaps() {
    local world="deployments/$TARGET_ENV/world.json" pkg app_cap missing=0
    if [[ ! -f "$world" ]]; then
        echo "ERROR: $world missing — needed for mvr.*.appCap" >&2
        exit 1
    fi
    for pkg in "$@"; do
        app_cap=$(jq -r --arg p "$pkg" '.mvr[$p].appCap // empty' "$world")
        if [[ -z "$app_cap" ]]; then
            echo "ERROR: mvr.$pkg.appCap missing — record with:" >&2
            echo "  ./scripts/mvr.sh set-appcap $TARGET_ENV $pkg <appCapId>" >&2
            missing=1
        fi
    done
    [[ "$missing" -eq 0 ]] || exit 1
}

# package-info → set-network → git-version.
ci_mvr_deploy_pkg() {
    local pkg=$1

    use_signer deployer
    run ./scripts/mvr.sh package-info "$TARGET_ENV" "$pkg"

    use_signer appcap
    run ./scripts/mvr.sh set-network "$TARGET_ENV" "$pkg"

    use_signer deployer
    run ./scripts/mvr.sh git-version "$TARGET_ENV" "$pkg" "$VERSION" "$COMMIT"
}

# git-version only (upgrade path). Args: package names...
ci_mvr_git_versions() {
    local pkg
    for pkg in "$@"; do
        run ./scripts/mvr.sh git-version "$TARGET_ENV" "$pkg" "$VERSION" "$COMMIT"
    done
}
