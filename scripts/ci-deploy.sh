#!/usr/bin/env bash
# In-container deploy orchestration for .github/workflows/deploy.yml.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

: "${TARGET_ENV:?}" "${MODE:?}" "${NET:?}" "${COMMIT:?}" "${DEPLOYER_KEY:?}" "${VERSION:?}"

# Packages in dependency order, matching deploy-world.sh.
PACKAGES="core character"

# Run a step, or just print it under DRY_RUN=1.
run() {
    if [[ "${DRY_RUN:-}" == "1" ]]; then echo "DRY_RUN: $*"; else "$@"; fi
}

setup
# Overriding the image entrypoint skips its sui init, so bootstrap config here.
sui_init_config "$NET" "$(get_rpc "$TARGET_ENV")"
DEPLOYER_ADDR=$(import_key "$DEPLOYER_KEY")
[[ -z "$DEPLOYER_ADDR" ]] && { echo "ERROR: could not import deployer key" >&2; exit 1; }
sui client switch --address "$DEPLOYER_ADDR" >/dev/null

# Get the deployment artifacts the workflow commits into one dir, so it can copy
# them out with a single docker cp and without re-deriving the package list.
export_artifacts() {
    local dir="deployments/$TARGET_ENV/records"
    rm -rf "$dir"
    for pkg in $PACKAGES; do
        mkdir -p "$dir/contracts/$pkg"
        cp "contracts/$pkg/Published.toml" "$dir/contracts/$pkg/Published.toml"
    done
    cp "deployments/$TARGET_ENV/world.json" "$dir/world.json"
}

# Publish/upgrade on the target network, then refresh the manifest + SDK preset.
run ./scripts/deploy-world.sh "$TARGET_ENV" "$MODE"

if [[ "$MODE" == "upgrade" ]]; then
    # Same lineage: target-network git metadata only. No mainnet, no AppCap.
    for pkg in $PACKAGES; do
        run ./scripts/mvr.sh git-version "$TARGET_ENV" "$pkg" "$VERSION" "$COMMIT"
    done
    export_artifacts
    exit 0
fi

# deploy mode: new lineage -> new PackageInfo, repoint the mainnet name, then
# record git metadata. set_network signs on mainnet with the AppCap holder;
# on testnet that's the deployer, so APPCAP_KEY is optional.
APPCAP_ADDR="$DEPLOYER_ADDR"
if [[ -n "${APPCAP_KEY:-}" ]]; then APPCAP_ADDR=$(import_key "$APPCAP_KEY"); fi

for pkg in $PACKAGES; do
    sui client switch --address "$DEPLOYER_ADDR" >/dev/null
    run ./scripts/mvr.sh package-info "$TARGET_ENV" "$pkg"

    sui client switch --address "$APPCAP_ADDR" >/dev/null
    run ./scripts/mvr.sh set-network "$TARGET_ENV" "$pkg"

    sui client switch --address "$DEPLOYER_ADDR" >/dev/null
    run ./scripts/mvr.sh git-version "$TARGET_ENV" "$pkg" "$VERSION" "$COMMIT"
done
export_artifacts
