#!/usr/bin/env bash
# In-container deploy orchestration for .github/workflows/deploy.yml.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/ci-deploy-lib.sh"

: "${TARGET_ENV:?}" "${MODE:?}" "${NET:?}" "${COMMIT:?}" "${DEPLOYER_KEY:?}" "${VERSION:?}"

# Packages in dependency order, matching deploy-world.sh.
PACKAGES=(core character inventory metadata)

setup
ci_bootstrap_keys

if [[ "$MODE" == "deploy" ]]; then
    ci_require_appcaps "${PACKAGES[@]}"
    ci_clear_published "${PACKAGES[@]}"
fi

run ./scripts/deploy-world.sh "$TARGET_ENV" "$MODE"

if [[ "$MODE" == "upgrade" ]]; then
    ci_mvr_git_versions "${PACKAGES[@]}"
    ci_export_artifacts "${PACKAGES[@]}"
    exit 0
fi

for pkg in "${PACKAGES[@]}"; do
    ci_mvr_deploy_pkg "$pkg"
done
ci_export_artifacts "${PACKAGES[@]}"
