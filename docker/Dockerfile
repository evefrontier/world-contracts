# Pinned Sui toolchain — keep in sync with Dockerfile.integration and CI.
ARG SUI_VERSION=testnet-v1.69.1
FROM mysten/sui-tools:${SUI_VERSION} AS dependency-stage

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

# Create the non-root user before installing so files are owned correctly at
# copy/install time — avoids a costly recursive chown of node_modules.
RUN groupadd -r deployer && \
    useradd -r -g deployer -m -d /home/deployer deployer

WORKDIR /app
RUN chown deployer:deployer /app
USER deployer

# Copy workspace manifests first for better layer caching, then install with pnpm
COPY --chown=deployer:deployer package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
RUN pnpm install --frozen-lockfile

COPY --chown=deployer:deployer . .

FROM dependency-stage AS build-stage
# Build all Move packages
RUN pnpm run build

FROM build-stage AS test-stage
# Run all Move package tests
RUN pnpm run test

# CI gate for pull requests: format + lint + test in the pinned toolchain.
# Each RUN is a separate cached layer and a distinct step in the build log.
FROM dependency-stage AS ci-stage
RUN pnpm run fmt:check
RUN pnpm run lint
RUN pnpm run test

FROM dependency-stage AS release-stage
ENV CI=true

# Copy pre-built contracts from build stage
COPY --from=build-stage /app/contracts ./contracts

# Make scripts executable
RUN chmod +x ./scripts/*.sh ./docker/entrypoint.sh

ENTRYPOINT ["./docker/entrypoint.sh"]
