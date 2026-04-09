# World Contracts

Sui Move smart contracts for EVE Frontier.

## Important Notice

This repository contains code intended for future use. While its not currently active in game or
production ready, it is being shared early for visibility, collaboration, review and reference.

The project is actively under development, and changes should be expected as work progresses.

For more context around this feel free to check out the [press release](https://www.ccpgames.com/news/2025/eve-frontier-to-launch-on-layer-1-blockchain-sui).

If you are looking for the current contracts used in game they can be found here: [projectawakening/world-chain-contracts](https://github.com/projectawakening/world-chain-contracts)

## Quick Start

### Prerequisites
- Docker (only for containerized deployment)
- OR Sui CLI + Node.js (for local development)

### Setup

1. **Create environment file and configure:**
   ```bash
   cp env.example .env
   ```

2. **Get your private key:**
   ```bash
   # If you have an existing Sui wallet:
   sui keytool export --address YOUR_ADDRESS
   
   # Or generate a new one:
   sui keytool generate ed25519
   
   # Copy the private key (without 0x prefix) to .env
   ```

## Docker Deployment

### Build Image
```bash
docker build -t world-contracts:latest --target release-stage -f docker/Dockerfile .
```

### Deploy & Configure
```bash
docker run --rm \
  -v "$(pwd)/.env:/app/.env:ro" \
  -v "$(pwd)/deployments:/app/deployments" \
  world-contracts:latest
```

On failure, check `deployments/<env>/deploy.log` for details.

## Localnet snapshot image

For a **pre-baked Sui localnet** Docker image (deployed contracts, Postgres-backed indexer, and object IDs for downstream integration tests), see **[`docker/README.md`](docker/README.md)**. It covers how to run the stack with [`docker/docker-compose-snapshot-image.yml`](docker/docker-compose-snapshot-image.yml) and where the image is published on GitHub Container Registry.

## Local Development

### Install Dependencies
```bash
npm install
```

### Build Contracts
```bash
npm run build
```

### Run Tests
```bash
npm run test
```

### Deploy Locally
```bash
# Uses SUI_NETWORK from .env (default: localnet)
pnpm deploy-world
```

## Documentation Automation

Whenever changes are **pushed to `main`**, the workflow at
[`.github/workflows/docs-update.yml`](.github/workflows/docs-update.yml)
automatically creates a **draft pull request** in
[`evefrontier/builder-documentation`](https://github.com/evefrontier/builder-documentation)
with a `@copilot` comment that instructs Copilot to update the relevant docs.

### How it works

1. The workflow triggers on `push` to `main`.
2. It resolves the merged PR associated with the push’s merge commit via
   `GET /repos/{owner}/{repo}/commits/{sha}/pulls` (skipping if none is found).
3. It fetches the list of changed files from the merged PR via the GitHub API.
4. It consults [`.github/docs-mapping.json`](.github/docs-mapping.json) to map
   changed source paths to documentation files in `builder-documentation`.
   - If no mapping matches, the fallback targets `smart-contracts/eve-frontier-world-explainer.md`.
5. A new branch (`docs/world-contracts-pr-<number>`) is created in
   `evefrontier/builder-documentation` with a scaffold placeholder commit.
6. A **draft PR** is opened in `builder-documentation` whose body contains:
   - A link to the merged `world-contracts` PR
   - A summary of changed files
   - Explicit `@copilot` instructions to update the identified docs
7. A follow-up PR comment is posted to ensure `@copilot` is notified.

### Required secret

Add the following secret to the `evefrontier/world-contracts` repository
(**Settings → Secrets and variables → Actions**):

| Secret name      | Description |
|------------------|-------------|
| `DOCS_REPO_PAT`  | A GitHub Personal Access Token (classic) **or** a fine-grained PAT with the following permissions on `evefrontier/builder-documentation`: `Contents: Read and write`, `Pull requests: Read and write`. |

> **Fine-grained PAT scopes** (recommended): resource owner = `evefrontier`,
> repository = `builder-documentation`, permissions = `Contents (read/write)` +
> `Pull requests (read/write)`.
>
> **Classic PAT scopes**: `repo` (full repository access).

### Customizing the path → docs mapping

Edit [`.github/docs-mapping.json`](.github/docs-mapping.json) to add or adjust
mappings. Each entry has:

```jsonc
{
  "paths": ["contracts/world/sources/assemblies/storage_unit"],  // path prefixes to match
  "docs":  ["smart-assemblies/storage-unit/README.md"],          // docs files to update
  "section": "Smart Assemblies - Storage Unit"                   // human-readable label
}
```

A `fallback` entry covers changes that don't match any specific path.

### Avoiding infinite loops

The workflow is scoped to `evefrontier/world-contracts` only and writes to a
different repository (`evefrontier/builder-documentation`). Changes in
`builder-documentation` do **not** trigger this workflow, so there is no
risk of an automation loop.
