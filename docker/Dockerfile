
FROM mysten/sui-tools:testnet-v1.64.0 AS dependency-stage

# Install system dependencies
RUN apt-get update && apt-get install -y \
    jq \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js, then enable pnpm via corepack
# (pnpm version is pinned by the "packageManager" field in package.json)
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && corepack enable \
    && rm -rf /var/lib/apt/lists/*

# Let corepack download the pinned pnpm without an interactive prompt
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0

# Verify installations
RUN sui --version && node --version && jq --version

WORKDIR /app

# Copy package files and install dependencies with pnpm
# (pnpm version is resolved from the "packageManager" field in package.json)
COPY package*.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm --version && pnpm install --no-frozen-lockfile

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
ENV CI=true

# Copy pre-built contracts from build stage
COPY --from=build-stage /app/contracts ./contracts

# Make scripts executable
RUN chmod +x ./scripts/*.sh ./docker/entrypoint.sh

ENTRYPOINT ["./docker/entrypoint.sh"]
