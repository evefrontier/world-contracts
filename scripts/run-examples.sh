#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/run-examples.sh            # default delay
#   ./scripts/run-examples.sh 3          # 3s delay between commands
#   DELAY_SECONDS=1 ./scripts/run-examples.sh

DELAY_SECONDS="${DELAY_SECONDS:-${1:-2}}"

commands=(
  "configure-fuel-energy"
  "create-character"
  "create-nwn"
  "deposit-fuel"
  "online-nwn"
  "create-storage-unit"
  "ssu-online"
  "deposit-to-ephemeral-inventory"
  "configure-gate-distance"
  "create-gates"
  "online-gates"
  "link-gates"
  "jump"
  "configure-builder-extension-rules"
  "authorise-gate"
  "authorise-storage-unit"
)

echo "Running ${#commands[@]} pnpm commands with ${DELAY_SECONDS}s delay..."

for i in "${!commands[@]}"; do
  step=$((i + 1))
  cmd="${commands[$i]}"

  echo
  echo "==> Step ${step}/${#commands[@]}: pnpm ${cmd}"
  pnpm "${cmd}"

  if [[ "${step}" -lt "${#commands[@]}" ]]; then
    sleep "${DELAY_SECONDS}"
  fi
done

echo
echo "Done."

