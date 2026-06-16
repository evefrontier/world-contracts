# Docker

Two Dockerfiles, three jobs. One pinned toolchain: `SUI_VERSION=testnet-v1.69.1`
(bump in both Dockerfiles and CI together).

| Image | File | Job |
|-------|------|-----|
| **integration** | [`Dockerfile.integration`](Dockerfile.integration) | localnet + deploy + run SDK integration tests |
| **snapshot** | [`Dockerfile.integration`](Dockerfile.integration) | bake the running chain into a downstream image (localnet + indexer + GraphQL) |
| **release** | [`Dockerfile`](Dockerfile) | pinned, self-contained artifact that deploys the world to a network |

Every deploy writes `deployments/<network>/world.json` — the manifest (chainId,
package ids, shared objects) the SDK and downstream read.

The localnet uses a [deterministic genesis](genesis/): four accounts
(`ADMIN`, `PLAYER_A/B/C`) derived from a public test mnemonic and funded at
genesis, identical every run.

## Integration tests

```bash
docker build -f docker/Dockerfile.integration -t world-integration .
docker run --rm -v "$(pwd):/app" -w /app -e CI=true world-integration test
```

Brings up the localnet, deploys `core` + `character`, runs the SDK integration
suite. Pass no argument instead of `test` to just leave the node running.

## Snapshot image

```bash
docker compose -f docker/docker-compose-snapshot-image.yml up
```

Runs a pre-baked chain (with Postgres for indexer + GraphQL) without deploying
anything. `world.json` is copied to the host at
`deployments/localnet-snapshot/world.json`. Ports: `9000` RPC · `9123` faucet ·
`9125` GraphQL. Bake one with
[`../scripts/bake-snapshot-image.sh`](../scripts/bake-snapshot-image.sh).

## Release image

Env-agnostic deploy vehicle: given `SUI_NETWORK` + `DEPLOYER_PRIVATE_KEY` (via
`.env` or env vars) it deploys the world and writes `world.json`. Logical envs
(dev/uat/test/live) and MVR are handled by a separate downstream workflow.

```bash
docker compose -f docker/compose.yml run --rm deploy   # reads ../.env
```
