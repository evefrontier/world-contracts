#!/usr/bin/env bash

set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
IMAGE_NAME="${IMAGE_NAME:-world-contracts}"
TAG="${TAG:-${GITHUB_REF_NAME:-local}}"

BAKER_IMAGE="${BAKER_IMAGE:-${IMAGE_NAME}-snapshot:baker}"
OUT_IMAGE="${REGISTRY}/${OWNER}/${IMAGE_NAME}:${TAG}"

PLATFORMS=(amd64 arm64)

MODE="${1:-}"
ARCH="${2:-}"

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

# Retry a flaky command N times with a delay between attempts.
retry() {
    local attempts="$1" delay="$2"
    shift 2
    local n=1
    until "$@"; do
        if [ "$n" -ge "$attempts" ]; then
            echo "ERROR: '$*' failed after ${attempts} attempts" >&2
            return 1
        fi
        echo "WARN: '$*' failed (attempt ${n}/${attempts}); retrying in ${delay}s..." >&2
        sleep "$delay"
        n=$((n + 1))
    done
}

# One ref per line: METADATA_TAGS if set, else the single OUT_IMAGE fallback.
refs() {
    if [ -n "$METADATA_TAGS" ]; then
        while IFS= read -r ref; do
            [ -n "$ref" ] && printf '%s\n' "$ref"
        done <<<"$METADATA_TAGS"
    else
        printf '%s\n' "$OUT_IMAGE"
    fi
}

case "$MODE" in
bake)
    # Assumes $BAKER_IMAGE is already built and loaded locally for this arch
    # (a preceding docker/build-push-action step does that, for GHA cache auth).
    valid_arch=0
    for p in "${PLATFORMS[@]}"; do [ "$p" = "$ARCH" ] && valid_arch=1; done
    if [ "$valid_arch" -ne 1 ]; then
        echo "ERROR: bake requires an arch argument, one of: ${PLATFORMS[*]}" >&2
        exit 1
    fi

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

    CIDS=()
    cleanup() {
        for cid in ${CIDS[@]+"${CIDS[@]}"}; do
            docker rm "$cid" >/dev/null 2>&1 || true
        done
    }
    trap cleanup EXIT

    # pnpm's store lives inside the container; mounting a host dir here lets
    # actions/cache persist it across runs instead of re-downloading every time.
    PNPM_STORE_DIR="${PNPM_STORE_DIR:-}"
    pnpm_mount_args=()
    if [ -n "$PNPM_STORE_DIR" ]; then
        mkdir -p "$PNPM_STORE_DIR"
        pnpm_mount_args=(-v "${PNPM_STORE_DIR}:/pnpm-store" -e PNPM_STORE_DIR=/pnpm-store)
    fi

    IMAGE_ID=""

    # Retried as a unit since the embedded localnet boot can still be racy.
    # set -e is suspended inside a retry/if! call, so guard each step explicitly.
    bake_one_arch() {
        echo "==> Baking ${ARCH} snapshot"

        # 1) Run bake container (mount workspace so pnpm install / deploy scripts can run)
        local cid
        cid="$(docker run -d --platform "linux/${ARCH}" -v "$(pwd):/app" \
            ${pnpm_mount_args[@]+"${pnpm_mount_args[@]}"} -w /app -e CI=true "$BAKER_IMAGE" snapshot)" || return 1
        CIDS+=("$cid")

        # 2) Wait for it to finish
        local status
        status="$(docker wait "$cid")" || return 1
        if [ "$status" != "0" ]; then
            docker logs "$cid" >&2 || true
            return 1
        fi

        # 3) Commit baked filesystem into an image
        IMAGE_ID="$(docker commit ${commit_args[@]+"${commit_args[@]}"} "$cid")" || return 1
        # Container wrote as root; runner user needs sudo to chmod it readable.
        if [ -n "$PNPM_STORE_DIR" ] && ! sudo -n chmod -R a+rX "$PNPM_STORE_DIR" 2>/dev/null; then
            echo "WARN: could not make ${PNPM_STORE_DIR} world-readable (no passwordless sudo); pnpm store cache may not persist" >&2
        fi
    }

    if ! retry 2 10 bake_one_arch; then
        echo "ERROR: baking ${ARCH} snapshot failed after retries" >&2
        exit 1
    fi

    while IFS= read -r ref; do
        arch_ref="${ref}-snapshot-${ARCH}"
        docker tag "$IMAGE_ID" "$arch_ref"
        retry 3 5 docker push "$arch_ref"
    done < <(refs)
    ;;

join)
    while IFS= read -r ref; do
        arch_refs=()
        for arch in "${PLATFORMS[@]}"; do
            arch_refs+=("${ref}-snapshot-${arch}")
        done
        retry 3 5 docker buildx imagetools create -t "${ref}-snapshot" "${arch_refs[@]}"
    done < <(refs)
    ;;

*)
    echo "ERROR: unknown mode '$MODE' (expected: bake <${PLATFORMS[*]// /|}> | join)" >&2
    exit 1
    ;;
esac
