#!/usr/bin/env bash
# Remove the [published.<env>] entry from each package's Published.toml so a fresh
# lineage can be published (sui refuses to re-publish an existing entry). Use only
# when intentionally starting a new lineage — it orphans the prior on-chain package
# and requires a new MVR set_network.
# Usage: ./scripts/reset-published.sh <dev|test|uat|live> [pkg...]
source "$(dirname "$0")/lib.sh"

setup
ENV=$(get_env "${1:-}")
shift || true
PKGS=("$@")
[ ${#PKGS[@]} -eq 0 ] && PKGS=(core character inventory freight)

if [[ "$ENV" == "localnet" ]]; then
    echo "reset-published: localnet has no committed Published.toml" >&2
    exit 1
fi

for pkg in "${PKGS[@]}"; do
    f="contracts/$pkg/Published.toml"
    [ -f "$f" ] || continue
    awk -v env="$ENV" '
        $0 ~ "^\\[published\\." env "\\]$" { skip = 1; next }
        skip && /^\[/ { skip = 0 }
        !skip { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "Removed [published.$ENV] from $f"
done
