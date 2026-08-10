# Docker

Two Dockerfiles. One pinned toolchain: `SUI_VERSION=testnet-v1.69.1` (plus
`PNPM_VERSION=9`), declared as build `ARG`s in each Dockerfile. To bump, update
together: both Dockerfiles, this README, and `genesis/genesis-config.yaml`'s
`protocol_version` (which must match the Sui version). The CI workflows build
these Dockerfiles, so they inherit the pin automatically — there is no tag to
edit in `pr.yml`.

| Stage / image | File | Used by |
|---------------|------|---------|
| **ci-stage** | [`Dockerfile`](Dockerfile) | `pr.yml` — format + lint + test contracts |
| **test-stage** | [`Dockerfile`](Dockerfile) | `release.yml` — build + test gate before release |
| **release-stage** | [`Dockerfile`](Dockerfile) | pinned, self-contained artifact that deploys the world to a network |
| **integration** | [`Dockerfile.integration`](Dockerfile.integration) | `pr.yml` — localnet + deploy + run SDK integration tests |
| **snapshot** | [`Dockerfile.integration`](Dockerfile.integration) | bake the running chain into a downstream image (localnet + indexer + GraphQL) |

Every deploy writes `deployments/<network>/world.json` — the manifest (chainId,
package ids, shared objects) the SDK and downstream read.

The localnet uses a [deterministic genesis](genesis/): five accounts
(`ADMIN`, `SPONSOR`, `PLAYER_A/B/C`) whose well-known test **private** keys are
committed in [`genesis/accounts.json`](genesis/accounts.json) and funded at
genesis (owned gas + address balance), identical every run. Deploy whitelists
`SPONSOR` on the AdminACL via `SPONSOR_ADDRESSES`.

## Integration tests

```bash
docker build -f docker/Dockerfile.integration -t world-integration .
docker run --rm -v "$(pwd):/app" -w /app -e CI=true world-integration test
```

Brings up the localnet, deploys world packages (`core`, `character`, `inventory`),
then `currency` (EVE) via a separate deploy script, runs the SDK integration
suite. Pass no argument instead of `test` to just leave the node running.

## Snapshot image

```bash
docker compose -f docker/docker-compose-snapshot-image.yml up
```

Runs a pre-baked chain (with Postgres for indexer + GraphQL) without deploying
anything. `world.json`, `accounts.json`, and `test-resources.json` are copied to
the host at `deployments/localnet-snapshot/`. Ports: `9000` RPC · `9123` faucet ·
`9125` GraphQL. Bake one with
[`../scripts/bake-snapshot-image.sh`](../scripts/bake-snapshot-image.sh).

`accounts.json` is [`genesis/accounts.json`](genesis/accounts.json) copied out at
bake time: the `role`, `address` and bech32 `privateKey` (`suiprivkey1…`, what
`Ed25519Keypair.fromSecretKey` takes) of every genesis account, so downstream
consumers can sign as `ADMIN`, `SPONSOR`, or any player. These private keys are
committed on purpose and are therefore public — never use these accounts on a
real network or fund them with real assets.

Bake also runs [`../scripts/seed-world.sh`](../scripts/seed-world.sh), which
creates resources  using the fixed ids in [`../test-resources.json`](../test-resources.json)
(`tenant: "local"`). Those entities live in the baked chain DB. Object ids are deterministic
```ts
const config = loadWorldConfig("deployments/localnet-snapshot/world.json");
deriveObjectId(config, { id: 900000001n, tenant: "local" }); // character
deriveObjectId(config, { id: 888800006n, tenant: "local" }); // storage unit itemId
```

`typeId` in `test-resources.json` is seed metadata for consumers (not an
on-chain create arg). Use the ids from that file.

## Release image

Env-agnostic deploy vehicle: given `SUI_NETWORK` + `DEPLOYER_PRIVATE_KEY` (via
`.env` or env vars) it deploys the world and writes `world.json`. Logical envs
(dev/uat/test/live) and MVR are handled by a separate downstream workflow.

```bash
docker compose -f docker/compose.yml run --rm deploy   # reads ../.env
```
