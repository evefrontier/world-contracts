# Snapshot image (local Sui + contracts)

Pre-built Docker image with a Sui **localnet**, deployed **world** and **builder** packages, and (with Postgres) indexer and GraphQL. Use it to run integration tests against a fixed chain from your laptop or CI.

## Run it locally

See **[`docker-compose-snapshot-image.yml`](docker-compose-snapshot-image.yml)** for a working example: Postgres, the snapshot service, ports, and env vars wired up.

From the repo root:

```bash
docker compose -f docker/docker-compose-snapshot-image.yml up
```

The compose file defaults to the published **`latest-snapshot`** tag (`ghcr.io/evefrontier/world-contracts:latest-snapshot`). Change `image:` if you want another tag from GHCR (see below).

## Where to get the image

Images are on **GitHub Container Registry**:

`ghcr.io/evefrontier/world-contracts:<tag>-snapshot`

Tags line up with releases (e.g. version numbers, `latest`). Check this repo’s **Packages** on GitHub for what’s available.

These images are published as **multi-arch manifests** (`linux/amd64` + `linux/arm64`), so Docker automatically pulls the variant matching your machine. On **Apple Silicon** that means a native `arm64` image — drop any `DOCKER_DEFAULT_PLATFORM=linux/amd64` override or `--platform linux/amd64` flag, which would otherwise force the slower emulated amd64 image.

## Object IDs on your machine (`extracted-object-ids.json`)

Tests need the **package and object IDs** that exist on this chain. The image ships that list as JSON.

**How it gets onto the host**

The compose file mounts a host folder onto `/data/deployment` in the container. A bind mount starts out empty on your machine, which would hide the file that’s baked into the image. On container start, the entrypoint **copies** the baked JSON from `/opt/world-contracts/extracted-object-ids.json` into `/data/deployment/extracted-object-ids.json`, overwriting any existing file. That write goes through the mount, so you end up with a real file on the host:

`deployments/localnet-snapshot/extracted-object-ids.json` (relative to the repo when you use the paths in the compose file).

**What’s in the file**

Small JSON with a `network` name and two groups of IDs:

- **`world`** — the published world package id and important shared objects (governor cap, registries, config objects, etc.).
- **`builder`** — the builder extension package id and related caps/config ids.

Your services or tests read these hex IDs when calling the chain (e.g. which package to target, which objects to pass into transactions).

## Accounts and keys on your machine (`accounts.json`)

Builders and service tests need to **act as** the accounts that exist on the baked chain, so the image also ships their private keys and addresses. Like the object IDs, this file is baked into the image and copied onto the host on container start:

`deployments/localnet-snapshot/accounts.json`

> ⚠️ **Test keys only.** These private keys are committed and public on purpose. They exist solely to drive the local snapshot chain. **Never** use these accounts on a real/public network or fund them with real assets.

Four **distinct** roles (`sponsor` is deliberately different from `governor`, `admin`, and the players):

- **`governor`** — deployed the contracts; owns the `GovernorCap`.
- **`admin`** — owns the builder `AdminCap`, is the registered server address, and is an admin in the `AdminACL`.
- **`sponsor`** — has lots of SUI, both a coin balance and an [address balance](https://docs.sui.io/onchain-finance/asset-custody/address-balances/) (EF-17526); added to the `AdminACL`.
- **`player`** — player A (`PLAYER_A`); owns a character on the baked chain.
- **`player_b`** — player B (`PLAYER_B`); second player for multi-user scripts and builder extensions.

Each entry has an `address` and a `privateKey` (Sui bech32 `suiprivkey1…`), ready to import with `sui keytool import` or load directly in the TS SDK. The same keys are committed at [`docker/genesis/accounts.json`](genesis/accounts.json).

## Integration image (localnet from scratch)

Build and run the same flow as CI (genesis, deploy, integration tests):

```bash
docker build -f docker/Dockerfile.integration -t world-integration .
docker run --rm -v "$(pwd):/app" -w /app -e CI=true world-integration test
```

On macOS, remove `node_modules` before `docker run` if you have run `pnpm install` on the host. The bind mount would otherwise bring Darwin `esbuild` binaries into the Linux container and publish scripts will fail. CI is unaffected (fresh checkout, no host `node_modules`).

```bash
rm -rf node_modules
docker run --rm -v "$(pwd):/app" -w /app -e CI=true world-integration test
```
