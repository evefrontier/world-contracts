# World Contracts

Sui Move smart contracts for EVE Frontier.

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

### Progress on V1 
TODO 
- Docker files update 
- Add agentic instructions 
- All README's
- scripts
