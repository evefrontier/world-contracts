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
