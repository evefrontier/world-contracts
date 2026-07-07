#!/usr/bin/env bash
#
# Assert that every final manifest (base and each "-snapshot" counterpart) is a
# multi-arch index containing all required platforms. Pure inspection — no image
# is pulled-and-run, so it can't be tripped up by emulation.
#
# Inputs (env):
#   FINAL_TAGS  Newline-separated list of fully-qualified base tags. Each is
#               checked, along with its "-snapshot" counterpart. Required.
#   PLATFORMS   Space-separated platforms that must be present.
#               Default: "linux/amd64 linux/arm64".

set -euo pipefail

FINAL_TAGS="${FINAL_TAGS:?FINAL_TAGS is required}"
PLATFORMS="${PLATFORMS:-linux/amd64 linux/arm64}"

read -ra required_platforms <<< "${PLATFORMS}"

fail=0

check() {
    local ref="$1"
    local out
    echo "== inspecting ${ref}"
    out="$(docker buildx imagetools inspect "${ref}")"
    echo "${out}"
    for plat in "${required_platforms[@]}"; do
        if ! grep -q "${plat}" <<< "${out}"; then
            echo "ERROR: ${ref} is missing platform ${plat}" >&2
            fail=1
        fi
    done
}

while IFS= read -r tag; do
    [ -z "$tag" ] && continue
    check "${tag}"
    check "${tag}-snapshot"
done <<< "${FINAL_TAGS}"

exit "${fail}"
