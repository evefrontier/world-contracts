#!/usr/bin/env bash
# In-container currency deploy for .github/workflows/deploy-currency.yml.
# Independent of world redeploys: publish/upgrade currency + MVR only.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/ci-deploy-lib.sh"

: "${TARGET_ENV:?}" "${MODE:?}" "${NET:?}" "${COMMIT:?}" "${DEPLOYER_KEY:?}" "${VERSION:?}"

PKG=currency

setup
ci_bootstrap_keys

if [[ "$MODE" == "deploy" ]]; then
    ci_require_appcaps "$PKG"
    ci_clear_published "$PKG"
fi

run ./scripts/deploy-currency.sh "$TARGET_ENV" "$MODE"

if [[ "$MODE" == "upgrade" ]]; then
    ci_mvr_git_versions "$PKG"
    ci_export_artifacts "$PKG"
    exit 0
fi

ci_mvr_deploy_pkg "$PKG"
ci_export_artifacts "$PKG"
