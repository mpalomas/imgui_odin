#!/usr/bin/env bash
# Prints the latest dear_bindings release for the Dear ImGui docking branch.
#
# Usage: tools/latest_dear_bindings.sh [--env]
#   --env  Print KEY=VALUE lines for CI: DEAR_BINDINGS_TAG, DEAR_BINDINGS_VERSION, IMGUI_TAG
#
# The releases are tagged DearBindings_v<version>_ImGui_v<imgui version>, with a -docking suffix for the
# docking branch. "Latest" is the most recently published one.
# Environment: GH_TOKEN  Optional, for the GitHub API (its anonymous rate limit is 60 requests an hour)

set -euo pipefail

die() {
    echo "error: $*" >&2
    exit 1
}

ENV=0
case "${1:-}" in
    --env) ENV=1 ;;
    "") ;;
    *) die "usage: tools/latest_dear_bindings.sh [--env]" ;;
esac
for tool in curl jq; do
    command -v "$tool" >/dev/null || die "$tool is required"
done

auth=()
if [[ -n "${GH_TOKEN:-}" ]]; then
    auth=(-H "Authorization: Bearer $GH_TOKEN")
fi
releases="$(curl -fsSL --retry 3 ${auth[@]+"${auth[@]}"} "https://api.github.com/repos/dearimgui/dear_bindings/releases?per_page=50")" ||
    die "cannot list the releases of dearimgui/dear_bindings"
TAG="$(jq -r '[.[] | select(.draft == false and .prerelease == false and (.tag_name | test("^DearBindings_v[0-9.]+_ImGui_v.*-docking$")))]
    | sort_by(.published_at) | last | .tag_name // ""' <<<"$releases")"
[[ -n "$TAG" ]] || die "no docking release found"

if [[ $ENV == 0 ]]; then
    echo "$TAG"
    exit 0
fi
[[ "$TAG" =~ ^DearBindings_v([0-9.]+)_ImGui_(v.*)$ ]] || die "unexpected tag $TAG"
echo "DEAR_BINDINGS_TAG=$TAG"
echo "DEAR_BINDINGS_VERSION=${BASH_REMATCH[1]}"
echo "IMGUI_TAG=${BASH_REMATCH[2]}"
