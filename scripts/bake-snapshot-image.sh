#!/usr/bin/env bash

set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
IMAGE_NAME="${IMAGE_NAME:-world-contracts}"
TAG="${TAG:-${GITHUB_REF_NAME:-local}}"

BAKER_IMAGE="${BAKER_IMAGE:-${IMAGE_NAME}-snapshot:baker}"
OUT_IMAGE="${REGISTRY}/${OWNER}/${IMAGE_NAME}:${TAG}"

# Requires a buildx builder + QEMU binfmt handlers registered on the host
# (the release-image job already sets both up before calling this script).
PLATFORMS=(amd64 arm64)

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

CIDS=()
cleanup() {
    for cid in "${CIDS[@]:-}"; do
        [ -n "$cid" ] && docker rm "$cid" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

# Build the --change LABEL args once; identical labels apply to every arch.
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

IMAGE_IDS=()

for i in "${!PLATFORMS[@]}"; do
    arch="${PLATFORMS[$i]}"
    echo "==> Baking ${arch} snapshot"

    # 1) Build the baker image for this arch (should run chain + deploy + exit 0).
    #    arm64 runs under QEMU emulation on an amd64 runner.
    baker_tag="${BAKER_IMAGE}-${arch}"
    docker buildx build --platform "linux/${arch}" -f docker/Dockerfile.integration -t "$baker_tag" --load .

    # 2) Run bake container (mount workspace so pnpm install / deploy scripts can run)
    cid="$(docker run -d --platform "linux/${arch}" -v "$(pwd):/app" -w /app -e CI=true "$baker_tag" snapshot)"
    CIDS+=("$cid")

    # 3) Wait for it to finish
    status="$(docker wait "$cid")"
    if [ "$status" != "0" ]; then
        docker logs "$cid" >&2 || true
        exit 1
    fi

    # 4) Commit baked filesystem into an image
    IMAGE_IDS[$i]="$(docker commit ${commit_args[@]+"${commit_args[@]}"} "$cid")"
done

# 5) Tag + push each arch, then join them into one multi-arch manifest per ref.
push_and_join() {
    local ref="$1"
    local arch_refs=()

    for i in "${!PLATFORMS[@]}"; do
        local arch="${PLATFORMS[$i]}"
        local arch_ref="${ref}-snapshot-${arch}"
        docker tag "${IMAGE_IDS[$i]}" "$arch_ref"
        docker push "$arch_ref"
        arch_refs+=("$arch_ref")
    done

    docker buildx imagetools create -t "${ref}-snapshot" "${arch_refs[@]}"
}

if [ -n "$METADATA_TAGS" ]; then
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        push_and_join "$ref"
    done <<<"$METADATA_TAGS"
else
    push_and_join "$OUT_IMAGE"
fi
