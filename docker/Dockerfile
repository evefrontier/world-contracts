
FROM mysten/sui-tools:testnet AS dependency-stage

# Install system dependencies
RUN apt-get update && apt-get install -y \
    jq \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js and pnpm
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pnpm \
    && rm -rf /var/lib/apt/lists/*

# Verify installations
RUN sui --version && node --version && pnpm --version && jq --version

WORKDIR /app

# Copy package files and install dependencies with pnpm
COPY package*.json pnpm-lock.yaml ./
RUN pnpm install --no-frozen-lockfile

COPY . .

# Run as deployer:deployer (non-root user)
RUN groupadd -r deployer && \
    useradd -r -g deployer -m -d /home/deployer deployer
RUN chown -R deployer:deployer /app
USER deployer

FROM dependency-stage AS lint-stage
RUN pnpm run fmt:check

FROM dependency-stage AS build-stage
# Build all Move contracts in parallel
RUN find contracts -maxdepth 1 -mindepth 1 -type d | \
    xargs -P 4 -I {} sui move build --path {}

FROM build-stage AS test-stage
# Run all tests in parallel
RUN find contracts -maxdepth 1 -mindepth 1 -type d | \
    xargs -P 4 -I {} sui move test --path {}

FROM dependency-stage AS release-stage
# Copy built artifacts from build stage
COPY --from=build-stage /app/contracts ./contracts
COPY --from=build-stage /app/scripts ./scripts

# Make deploy script executable
RUN chmod +x ./scripts/deploy.sh

# Default command
CMD ["bash", "-c", "echo 'Sui World Contracts Deployer' && echo 'Run: ./scripts/deploy.sh --env=<testnet|devnet|localnet>' && bash"]
