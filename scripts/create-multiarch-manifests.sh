#!/usr/bin/env bash
#
# Assemble multi-arch manifests for the base and snapshot images from the
# per-arch image digests produced by the bake matrix. Each final base tag gets
# a manifest, and the snapshot image reuses each tag with a "-snapshot" suffix.
# Referencing images by digest (not by the temp tags) keeps this race-safe.
#
# Inputs (env):
#   BASE_NAME    Fully-qualified image name without tag
#                (e.g. ghcr.io/evefrontier/world-contracts). Required.
#   FINAL_TAGS   Newline-separated list of fully-qualified final tags for the
#                base image (docker/metadata-action output). Required.
#   DIGEST_DIR   Directory holding the per-arch digest files, laid out as
#                base/<arch> and snapshot/<arch>. Default: /tmp/digests.

set -euo pipefail

BASE_NAME="${BASE_NAME:?BASE_NAME is required}"
FINAL_TAGS="${FINAL_TAGS:?FINAL_TAGS is required}"
DIGEST_DIR="${DIGEST_DIR:-/tmp/digests}"

base_amd64="$(cat "${DIGEST_DIR}/base/amd64")"
base_arm64="$(cat "${DIGEST_DIR}/base/arm64")"
snap_amd64="$(cat "${DIGEST_DIR}/snapshot/amd64")"
snap_arm64="$(cat "${DIGEST_DIR}/snapshot/arm64")"

for d in "$base_amd64" "$base_arm64" "$snap_amd64" "$snap_arm64"; do
    case "$d" in
        sha256:*) : ;;
        *) echo "ERROR: missing or malformed digest: '$d'" >&2; exit 1 ;;
    esac
done

while IFS= read -r tag; do
    [ -z "$tag" ] && continue

    echo "== base manifest: ${tag}"
    docker buildx imagetools create -t "${tag}" \
        "${BASE_NAME}@${base_amd64}" "${BASE_NAME}@${base_arm64}"

    echo "== snapshot manifest: ${tag}-snapshot"
    docker buildx imagetools create -t "${tag}-snapshot" \
        "${BASE_NAME}@${snap_amd64}" "${BASE_NAME}@${snap_arm64}"
done <<< "${FINAL_TAGS}"
