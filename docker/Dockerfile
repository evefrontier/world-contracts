
# mysten/sui-tools has no multi-arch manifest: amd64 lives under the plain tag,
# arm64 under a separate "-arm64" tag. Declare both and let BuildKit pick the one
# matching the build's TARGETARCH (base-amd64 / base-arm64), so a native arm64
# build (Apple Silicon) gets a real arm64 base instead of an emulated amd64 one.
ARG SUI_TOOLS_VERSION=testnet-v1.75.1
FROM mysten/sui-tools:${SUI_TOOLS_VERSION} AS base-amd64
FROM mysten/sui-tools:${SUI_TOOLS_VERSION}-arm64 AS base-arm64

ARG TARGETARCH
FROM base-${TARGETARCH} AS dependency-stage

# Install system dependencies
RUN apt-get update && apt-get install -y \
    jq \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install the Node version pinned in .nvmrc, then enable pnpm via corepack.
# (pnpm version is pinned by the "packageManager" field in package.json)
ARG TARGETARCH
COPY .nvmrc /tmp/.nvmrc
RUN NODE_VERSION="$(tr -d '[:space:]' < /tmp/.nvmrc)" \
    && case "${TARGETARCH}" in \
    amd64) node_arch=x64 ;; \
    arm64) node_arch=arm64 ;; \
    *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.gz" \
    | tar -xz -C /usr/local --strip-components=1 \
    && corepack enable \
    && rm /tmp/.nvmrc \
    && node -v | grep -qx "v${NODE_VERSION}"

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
# Build all Move contracts in parallel. The first `sui` invocation creates
# ~/.sui/{client.yaml,sui.aliases}; running several in parallel (xargs -P 4)
# makes concurrent first-runs race and corrupt those files ("EOF while parsing
# a value", "Cannot deserialize aliases file"), which fails the build
# nondeterministically. Build one package serially first to create the config,
# then build them all in parallel against the now-existing config.
RUN set -eu; \
    first="$(find contracts -maxdepth 1 -mindepth 1 -type d | head -n1)"; \
    sui move build --path "$first"; \
    find contracts -maxdepth 1 -mindepth 1 -type d | \
    xargs -P 4 -I {} sui move build --path {}

FROM build-stage AS test-stage
# Run all tests in parallel. Safe to parallelize: the Sui config was already
# created in build-stage and is inherited via this FROM, so there is no
# concurrent first-run config race here.
RUN find contracts -maxdepth 1 -mindepth 1 -type d | \
    xargs -P 4 -I {} sui move test --path {}

FROM dependency-stage AS release-stage
ENV CI=true

# Copy pre-built contracts from build stage
COPY --from=build-stage /app/contracts ./contracts

# Make scripts executable
RUN chmod +x ./scripts/*.sh ./docker/entrypoint.sh

ENTRYPOINT ["./docker/entrypoint.sh"]
