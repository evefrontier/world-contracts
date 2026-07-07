#!/usr/bin/env bash

set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
IMAGE_NAME="${IMAGE_NAME:-world-contracts}"

BAKER_IMAGE="${BAKER_IMAGE:-${IMAGE_NAME}-snapshot:baker}"

# The single, fixed per-arch temp ref this bake pushes to. CI sets this to a
# tag like ghcr.io/<owner>/world-contracts:snapshot-tmp-<arch>; the tag is
# reused (self-overwriting) each release so it never accumulates. The multi-arch
# manifest is assembled downstream from the pushed image's digest, not this tag.
SNAPSHOT_OUT_REF="${SNAPSHOT_OUT_REF:-${REGISTRY}/${OWNER}/${IMAGE_NAME}:snapshot-tmp-local}"

# Optional: file to write the pushed image digest (sha256:...) to, so CI can
# upload it as an artifact and stitch the multi-arch manifest by digest.
SNAPSHOT_DIGEST_FILE="${SNAPSHOT_DIGEST_FILE:-}"

# Optional: newline-separated key=value labels (docker/metadata-action output)
# baked onto the committed image.
METADATA_LABELS="${METADATA_LABELS:-}"

if [ -z "$OWNER" ]; then
    echo "ERROR: OWNER is empty. Set OWNER or GITHUB_REPOSITORY_OWNER." >&2
    exit 1
fi

if [ -z "$IMAGE_NAME" ]; then
    echo "ERROR: IMAGE_NAME is empty. Set IMAGE_NAME to the desired image name." >&2
    exit 1
fi

if [ -z "$SNAPSHOT_OUT_REF" ]; then
    echo "ERROR: SNAPSHOT_OUT_REF is empty. Set SNAPSHOT_OUT_REF to the per-arch temp ref." >&2
    exit 1
fi

cleanup() {
    if [ -n "${CID:-}" ]; then
        docker rm "$CID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# 1) Build the baker image (should run chain + deploy + exit 0).
#    Native to the runner arch: on an arm64 runner suiup fetches the arm64 sui
#    binary, so the committed snapshot is a genuine arm64 image.
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

# 5) Tag + push the single fixed temp ref, then record the pushed digest so the
#    merge job can build the multi-arch manifest by digest (race-safe, no cleanup).
docker tag "$IMAGE_ID" "$SNAPSHOT_OUT_REF"
push_output="$(docker push "$SNAPSHOT_OUT_REF")"
printf '%s\n' "$push_output"

digest="$(printf '%s\n' "$push_output" | grep -oE 'sha256:[0-9a-f]{64}' | head -n1 || true)"

if [ -z "$digest" ]; then
    # Fallback: read the digest back from the local image's RepoDigests.
    repo="${SNAPSHOT_OUT_REF%:*}"
    digest="$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$SNAPSHOT_OUT_REF" \
        | grep -oE "${repo}@sha256:[0-9a-f]{64}" | grep -oE 'sha256:[0-9a-f]{64}' | head -n1 || true)"
fi

if [ -z "$digest" ]; then
    echo "ERROR: could not determine pushed image digest for $SNAPSHOT_OUT_REF" >&2
    exit 1
fi

echo "Pushed ${SNAPSHOT_OUT_REF} (${digest})"

if [ -n "$SNAPSHOT_DIGEST_FILE" ]; then
    mkdir -p "$(dirname "$SNAPSHOT_DIGEST_FILE")"
    printf '%s\n' "$digest" >"$SNAPSHOT_DIGEST_FILE"
    echo "Wrote digest to ${SNAPSHOT_DIGEST_FILE}"
fi
