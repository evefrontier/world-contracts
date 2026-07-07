#!/usr/bin/env bash
#
# Persist the base image's per-arch digest to the shared digest directory so the
# merge job can assemble the multi-arch manifest. Written to
# <DIGEST_DIR>/base/<ARCH>.
#
# Inputs (env):
#   BASE_DIGEST  The sha256:... digest emitted by the base image build. Required.
#   ARCH         Architecture key (amd64 / arm64). Required.
#   DIGEST_DIR   Root directory for digest files. Default: /tmp/digests.

set -euo pipefail

BASE_DIGEST="${BASE_DIGEST:?BASE_DIGEST is required}"
ARCH="${ARCH:?ARCH is required}"
DIGEST_DIR="${DIGEST_DIR:-/tmp/digests}"

case "$BASE_DIGEST" in
    sha256:*) : ;;
    *) echo "ERROR: BASE_DIGEST is not a sha256 digest: '$BASE_DIGEST'" >&2; exit 1 ;;
esac

mkdir -p "${DIGEST_DIR}/base"
printf '%s\n' "$BASE_DIGEST" > "${DIGEST_DIR}/base/${ARCH}"
echo "Wrote base digest for ${ARCH}: ${BASE_DIGEST}"
