#!/usr/bin/env bash
# Create test resources after deploying and configuring world.
# Usage: ./scripts/seed-world.sh [localnet|dev|test|uat|live] [delay_seconds]
source "$(dirname "$0")/lib.sh"

setup
ENV=$(get_env "${1:-}")
mkdir -p "deployments/$ENV"
start_logging "$ENV" "create test resources"
export SUI_NETWORK="$ENV"

DELAY_SECONDS="${DELAY_SECONDS:-${2:-5}}"

# Populated when seed steps exist (e.g. create test characters on-chain).
# TODO(seed): add `create:character` here so the snapshot image ships with a
# character on-chain. Blocked on one wiring gap in create-character.ts: it
# hardcodes deployments/localnet/world.json — drive it off SUI_NETWORK. (Keys are
# available: the bake exports ADMIN as SUI_PRIVATE_KEY, and the player keys are in
# docker/genesis/accounts.json.)
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
