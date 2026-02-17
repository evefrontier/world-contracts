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
