ARG SUI_VERSION=testnet-v1.75.1
ARG PNPM_VERSION=9
FROM mysten/sui-tools:${SUI_VERSION} AS dependency-stage

# sui-tools is Debian 11. debian-security currently 404s rotated pool debs
# (e.g. curl 7.74.0-1.3+deb11u16). Use main + updates only.
RUN find /etc/apt -name '*.list' -exec sed -i '/security/s/^/#/' {} + \
    && apt-get update \
    && apt-get install -y --no-install-recommends jq curl \
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

# Pre-create client.yaml so parallel `sui move build` does not race on first-run init.
RUN mkdir -p /home/deployer/.sui/sui_config \
    && printf '%s\n' '[]' > /home/deployer/.sui/sui_config/sui.keystore \
    && chmod 600 /home/deployer/.sui/sui_config/sui.keystore \
    && printf '%s\n' \
    '---' \
    'keystore:' \
    '  File: /home/deployer/.sui/sui_config/sui.keystore' \
    'envs:' \
    '  - alias: testnet' \
    '    rpc: "https://fullnode.testnet.sui.io:443"' \
    '    ws: ~' \
    '    basic_auth: ~' \
    'active_env: testnet' \
    'active_address: ~' \
    > /home/deployer/.sui/sui_config/client.yaml \
    && test -s /home/deployer/.sui/sui_config/client.yaml

# Copy workspace manifests first for better layer caching, then install with pnpm
COPY --chown=deployer:deployer package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
RUN pnpm install --frozen-lockfile

COPY --chown=deployer:deployer . .

FROM dependency-stage AS build-stage
RUN pnpm run build

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
