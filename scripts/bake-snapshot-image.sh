#!/usr/bin/env bash

set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
IMAGE_NAME="${IMAGE_NAME:-world-contracts}"
TAG="${TAG:-${GITHUB_REF_NAME:-local}}"

BAKER_IMAGE="${BAKER_IMAGE:-${IMAGE_NAME}-snapshot:baker}"
OUT_IMAGE="${REGISTRY}/${OWNER}/${IMAGE_NAME}:${TAG}"

if [ -z "$OWNER" ]; then
    echo "ERROR: OWNER is empty. Set OWNER or GITHUB_REPOSITORY_OWNER." >&2
    exit 1
fi

if [ -z "$IMAGE_NAME" ]; then
    echo "ERROR: IMAGE_NAME is empty. Set IMAGE_NAME to the desired image name." >&2
    exit 1
fi

if [ -z "$TAG" ]; then
    echo "ERROR: TAG is empty. Set TAG or GITHUB_REF_NAME." >&2
    exit 1
fi

# Optional: pass through docker/metadata-action outputs (multiline strings).
# - METADATA_TAGS: newline-separated image refs (e.g. ghcr.io/org/img:1.2.3)
# - METADATA_LABELS: newline-separated key=value labels
METADATA_TAGS="${METADATA_TAGS:-}"
METADATA_LABELS="${METADATA_LABELS:-}"

cleanup() {
    if [ -n "${CID:-}" ]; then
        docker rm "$CID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# 1) Build the baker image (should run chain + deploy + exit 0)
docker build -f docker/Dockerfile.integration -t "$BAKER_IMAGE" .

# 2) Run bake container (mount workspace so pnpm install / deploy scripts can run)
CID="$(docker run -d -v "$(pwd):/app" -w /app -e CI=true "$BAKER_IMAGE" snapshot)"

# 3) Wait for it to finish
STATUS="$(docker wait "$CID")"
if [ "$STATUS" != "0" ]; then
    docker logs "$CID" >&2 || true
    exit 1
fi

# 4) Commit baked filesystem into an image
commit_args=()
if [ -n "$METADATA_LABELS" ]; then
    while IFS= read -r label; do
        [ -z "$label" ] && continue

        if [[ "$label" == *"="* ]]; then
            key=${label%%=*}
            value=${label#*=}

            # Escape backslashes and double quotes for safe inclusion in a double-quoted value.
            value_escaped=${value//\\/\\\\}
            value_escaped=${value_escaped//\"/\\\"}

            commit_args+=(--change "LABEL ${key}=\"${value_escaped}\"")
        else
            # Fallback: no '=' present, preserve original behavior.
            commit_args+=(--change "LABEL $label")
        fi
    done <<<"$METADATA_LABELS"
fi

IMAGE_ID="$(docker commit "${commit_args[@]}" "$CID")"

# 5) Tag + push
if [ -n "$METADATA_TAGS" ]; then
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        docker tag "$IMAGE_ID" "${ref}-snapshot"
        docker push "${ref}-snapshot"
    done <<<"$METADATA_TAGS"
else
    docker tag "$IMAGE_ID" "${OUT_IMAGE}-snapshot"
    docker push "${OUT_IMAGE}-snapshot"
fi
