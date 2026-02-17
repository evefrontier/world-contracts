#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/run-integration-test.sh            # default delay
#   ./scripts/run-integration-test.sh 3          # 3s delay between commands
#   DELAY_SECONDS=1 ./scripts/run-integration-test.sh

DELAY_SECONDS="${DELAY_SECONDS:-${1:-2}}"

commands=(
  "create-character"
  "create-nwn"
  "deposit-fuel"
  "online-nwn"
  "create-storage-unit"
  "ssu-online"
  "game-item-to-chain"
  "withdraw-deposit"
  "chain-item-to-game"
  "create-gates"
  "online-gates"
  "link-gates"
  "jump"
  "configure-builder-extension-rules"
  "authorise-gate"
  "authorise-storage-unit"
  "deposit-to-ephemeral-inventory"
  "issue-tribe-jump-permit"
  "jump-with-permit"
  "collect-corpse-bounty"
  "create-assembly"
  "online"
  "update-fuel"
  "offline-nwn"
  "unanchor-nwn"
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

