#!/usr/bin/env bash
# Shared helpers for ci-deploy.sh / ci-deploy-currency.sh (sourced, not executed).

# Run a step, or just print it under DRY_RUN=1.
run() {
    if [[ "${DRY_RUN:-}" == "1" ]]; then echo "DRY_RUN: $*"; else "$@"; fi
}

# Import deployer (+ optional AppCap) keys, init client, export SUI_PRIVATE_KEY.
# Sets: DEPLOYER_ADDR, APPCAP_ADDR
ci_bootstrap_keys() {
    : "${TARGET_ENV:?}" "${NET:?}" "${DEPLOYER_KEY:?}"

    sui_init_config "$NET" "$(get_rpc "$TARGET_ENV")"
    DEPLOYER_ADDR=$(import_key "$DEPLOYER_KEY")
    [[ -z "$DEPLOYER_ADDR" ]] && { echo "ERROR: could not import deployer key" >&2; exit 1; }
    sui client switch --address "$DEPLOYER_ADDR" >/dev/null
    export SUI_PRIVATE_KEY="$DEPLOYER_KEY"

    APPCAP_ADDR="$DEPLOYER_ADDR"
    if [[ -n "${APPCAP_KEY:-}" ]]; then
        APPCAP_ADDR=$(import_key "$APPCAP_KEY")
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

    sui client switch --address "$DEPLOYER_ADDR" >/dev/null
    run ./scripts/mvr.sh package-info "$TARGET_ENV" "$pkg"

    sui client switch --address "$APPCAP_ADDR" >/dev/null
    run ./scripts/mvr.sh set-network "$TARGET_ENV" "$pkg"

    sui client switch --address "$DEPLOYER_ADDR" >/dev/null
    run ./scripts/mvr.sh git-version "$TARGET_ENV" "$pkg" "$VERSION" "$COMMIT"
}

# git-version only (upgrade path). Args: package names...
ci_mvr_git_versions() {
    local pkg
    for pkg in "$@"; do
        run ./scripts/mvr.sh git-version "$TARGET_ENV" "$pkg" "$VERSION" "$COMMIT"
    done
}
