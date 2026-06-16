#!/usr/bin/env bash
# Create test resources after deploying and configuring world.
# Usage: ./scripts/seed-world.sh [localnet|testnet|mainnet|devnet] [delay_seconds]
source "$(dirname "$0")/lib.sh"

setup
ENV=$(get_env "${1:-}")
mkdir -p "deployments/$ENV"
start_logging "$ENV" "create test resources"
export SUI_NETWORK="$ENV"

DELAY_SECONDS="${DELAY_SECONDS:-${2:-5}}"

# Populated when seed steps exist (e.g. create test characters on-chain).
commands=(
)

echo "Seeding world on $ENV: ${#commands[@]} steps with ${DELAY_SECONDS}s delay..."

for i in "${!commands[@]}"; do
  step=$((i + 1))
  cmd="${commands[$i]}"

  echo
  echo "==> Step ${step}/${#commands[@]}: ${cmd}"
  pnpm "${cmd}"

  if [[ "${step}" -lt "${#commands[@]}" ]]; then
    sleep "${DELAY_SECONDS}"
  fi
done

echo
echo "Test Resources created for world in $ENV."
