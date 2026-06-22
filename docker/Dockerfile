ARG SUI_VERSION=testnet-v1.69.1
ARG PNPM_VERSION=9
FROM mysten/sui-tools:${SUI_VERSION} AS dependency-stage

# Install system dependencies, Node.js, and pnpm in a single layer
RUN apt-get update && apt-get install -y --no-install-recommends jq curl \
    && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g "pnpm@${PNPM_VERSION}" \
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
RUN pnpm run build

FROM dependency-stage AS ci-stage
RUN sui client --yes envs >/dev/null 2>&1 || true
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
