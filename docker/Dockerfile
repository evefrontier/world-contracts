# Use the official Sui tools Docker image
FROM mysten/sui-tools:devnet

# Install additional dependencies needed for this project
RUN apt-get update && apt-get install -y \
    jq \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (for npm build/install)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Verify installations
RUN sui --version && node --version && jq --version

WORKDIR /app
COPY . .

RUN npm install
RUN npm run build
RUN chmod +x ./scripts/deploy.sh

CMD ["bash", "-c", "echo 'Sui World Contracts Deployer' && echo 'Run: ./scripts/deploy.sh --env=<testnet|devnet|localnet|mainnet>' && bash"]