---
name: localnet-integration
description: Launch a deterministic local Sui network with the world contracts deployed, and run the SDK integration tests against it. Use when asked to "run integration tests", "start/stop localnet", "test against a local chain", "deploy to localnet", "spin up the snapshot chain", or to verify a Move/SDK change end-to-end on a real node.
---

# Localnet + integration tests

Everything runs in Docker (`docker/Dockerfile.integration`, pinned Sui toolchain), so the
host only needs Docker, `jq`, and `pnpm`. Use the helper — don't hand-roll `sui start`:

```bash
agentictools/skills/localnet-integration/run.sh <mode>
```



## Pick a mode


| Goal                           | Mode                           | Notes                                                                                                                                                                 |
| ------------------------------ | ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| One-shot CI-equivalent run     | `test`                         | Fresh genesis → deploy → seed → full SDK suite → exits. Same as `pr.yml`. Slowest but authoritative.                                                                  |
| Iterate on tests               | `up`, then `host-test`         | Leaves the chain running detached (`world-localnet`); rerun tests from the host as often as needed. Pass a filter: `host-test src/__integration__/inventory.test.ts`. |
| Inspect / debug chain          | `logs`, `down`                 | `down` when finished — always clean up.                                                                                                                               |
| Downstream / indexer / GraphQL | `snapshot-up`, `snapshot-down` | Pre-baked image from GHCR, no deploy. Does **not** reflect local contract changes.                                                                                    |


Move contract changed? `test` or a fresh `up` — the chain redeploys from the mounted repo
on every start; no image rebuild needed for source changes.

## What you get

- RPC `127.0.0.1:9000`, faucet `:9123` (GraphQL `:9125` in snapshot mode).
- Manifest: `deployments/localnet/world.json` (snapshot: `deployments/localnet-snapshot/`).
- Accounts: `docker/genesis/accounts.json` — `ADMIN`, `SPONSOR`, `PLAYER_A/B/C`, `EXCHANGE`,
funded at genesis, identical every run. `host-test` exports `SUI_PRIVATE_KEY` /
`WORLD_ADMIN_ADDRESS` from `ADMIN`.
- Seeded entities with fixed ids: `test-resources.json`.
- Tests live in `sdk/world-sdk/src/__integration__/`; shared setup in `helpers.ts`.



## When it fails

1. Read the `[integration]` log lines — they name the failing step (genesis, RPC wait,
  send-funds, `deploy-world.sh`, `deploy-currency.sh`, `seed-world.sh`, tests).
2. Move abort codes: decode with `tools/error-decoder` (`pnpm build:decoder`).
3. Node never ready / genesis error after a Sui bump: `SUI_VERSION` in both Dockerfiles must
  match `protocol_version` in `docker/genesis/genesis-config.yaml` (see `docker/README.md`).
4. Port in use: a previous `up` or snapshot stack is still running → `down` / `snapshot-down`.
5. Host tests crash on native modules: the container installs Linux `node_modules` into the
  mounted repo; `host-test` reinstalls, but run `pnpm install` manually if you ran `test`.



## Rules

- Genesis private keys are committed and public. Never use them on testnet/mainnet.
- Don't edit `deployments/localnet/` by hand; it's regenerated each run.

