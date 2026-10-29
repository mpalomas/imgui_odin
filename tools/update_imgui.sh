#!/usr/bin/env bash
# Imports a dear_bindings release and the matching Dear ImGui sources into upstream/, and regenerates the
# Odin bindings.
#
# Usage: tools/update_imgui.sh [--sources-only] [DEAR_BINDINGS_TAG]
#   DEAR_BINDINGS_TAG  e.g. DearBindings_v0.26_ImGui_v1.93.0-docking (default: the one in
#                      upstream/version.env)
#   --sources-only     Only import the sources: no Odin needed.
#
# Downloads the release's dcimgui files, checked against the SHA-256 digests GitHub lists for them, and
# clones ocornut/imgui at the tag the release names (ImGui_v1.93.0-docking: v1.93.0-docking). Checks
# that both are the same ImGui version, replaces upstream/imgui/ and upstream/dear_bindings/, writes
# upstream/version.env, then runs tools/gen and, when the generator exists and a C++ compiler is
# installed, builds the library and checks the bindings against it.
# Environment:
#   ODIN      (default: odin from PATH, else ~/dev/odin/Odin/odin)
#   GH_TOKEN  Optional, for the GitHub API (its anonymous rate limit is 60 requests an hour)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ODIN="${ODIN:-$(command -v odin || echo "$HOME/dev/odin/Odin/odin")}"
VERSION_ENV="$REPO/upstream/version.env"
SLUG=dearimgui/dear_bindings

# The release files the bindings use. dcimgui.h is the API with the default argument helpers, kept as a
# reference to read.
BINDING_FILES=(
    dcimgui_nodefaultargfunctions.h
    dcimgui_nodefaultargfunctions.cpp
    dcimgui_nodefaultargfunctions.json
    dcimgui.h
    LICENSE.txt
)
# The Dear ImGui files the library is built from. No backends.
IMGUI_FILES=(
    imgui.h imgui.cpp imgui_draw.cpp imgui_tables.cpp imgui_widgets.cpp imgui_demo.cpp imgui_internal.h
    imstb_rectpack.h imstb_textedit.h imstb_truetype.h imconfig.h LICENSE.txt
)

die() {
    echo "error: $*" >&2
    exit 1
}

for tool in curl git jq; do
    command -v "$tool" >/dev/null || die "$tool is required"
done

SOURCES_ONLY=0
if [[ "${1:-}" == --sources-only ]]; then
    SOURCES_ONLY=1
    shift
fi
if [[ $# -gt 0 ]]; then
    TAG="$1"
else
    [[ -f "$VERSION_ENV" ]] || die "no $VERSION_ENV: pass a dear_bindings release tag"
    TAG="$(sed -n 's/^DEAR_BINDINGS_TAG=//p' "$VERSION_ENV")"
    [[ -n "$TAG" ]] || die "no DEAR_BINDINGS_TAG in $VERSION_ENV"
fi
# DearBindings_v0.26_ImGui_v1.93.0-docking
[[ "$TAG" =~ ^DearBindings_v([0-9.]+)_ImGui_(v[0-9][0-9A-Za-z.-]*)$ ]] ||
    die "'$TAG' is not a tag like DearBindings_v0.26_ImGui_v1.93.0-docking"
DEAR_BINDINGS_VERSION="${BASH_REMATCH[1]}"
IMGUI_TAG="${BASH_REMATCH[2]}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

api() {
    local auth=()
    if [[ -n "${GH_TOKEN:-}" ]]; then
        auth=(-H "Authorization: Bearer $GH_TOKEN")
    fi
    curl -fsSL --retry 3 -H "Accept: application/vnd.github+json" ${auth[@]+"${auth[@]}"} "https://api.github.com/$1"
}

sha256() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}

echo "Downloading release $TAG of $SLUG"
release="$(api "repos/$SLUG/releases/tags/$TAG")" || die "cannot get the release $TAG of $SLUG"
mkdir -p "$TMP/dear_bindings"
for f in "${BINDING_FILES[@]}"; do
    asset="$(jq -c --arg f "$f" '.assets[] | select(.name == $f)' <<<"$release")"
    [[ -n "$asset" ]] || die "release $TAG has no $f"
    curl -fsSL --retry 3 -o "$TMP/dear_bindings/$f" "$(jq -r .browser_download_url <<<"$asset")" ||
        die "cannot download $f"
    want="$(jq -r '.digest // ""' <<<"$asset")"
    if [[ "$want" == sha256:* ]]; then
        [[ "$(sha256 "$TMP/dear_bindings/$f")" == "${want#sha256:}" ]] || die "checksum mismatch for $f"
    else
        echo "warning: GitHub lists no SHA-256 digest for $f" >&2
    fi
done

echo "Cloning ocornut/imgui at $IMGUI_TAG"
# Its output only on failure: a shallow clone of an annotated tag warns that the tag "is not a commit".
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$IMGUI_TAG" \
    https://github.com/ocornut/imgui.git "$TMP/imgui-src" 2>"$TMP/clone.log" || {
    cat "$TMP/clone.log" >&2
    die "cannot clone ocornut/imgui at $IMGUI_TAG"
}
IMGUI_COMMIT="$(git -C "$TMP/imgui-src" rev-parse HEAD)"
mkdir -p "$TMP/imgui"
for f in "${IMGUI_FILES[@]}"; do
    [[ -f "$TMP/imgui-src/$f" ]] || die "ImGui $IMGUI_TAG has no $f"
    cp "$TMP/imgui-src/$f" "$TMP/imgui/"
done

# `#define IMGUI_VERSION_NUM 19300` in both headers.
version_num() {
    sed -n 's/^#define[[:space:]]*IMGUI_VERSION_NUM[[:space:]]*\([0-9]*\).*/\1/p' "$1" | head -n 1
}
IMGUI_VERSION_NUM="$(version_num "$TMP/imgui/imgui.h")"
bindings_num="$(version_num "$TMP/dear_bindings/dcimgui_nodefaultargfunctions.h")"
[[ -n "$IMGUI_VERSION_NUM" ]] || die "no IMGUI_VERSION_NUM in imgui.h"
[[ "$IMGUI_VERSION_NUM" == "$bindings_num" ]] ||
    die "ImGui $IMGUI_TAG is version $IMGUI_VERSION_NUM, the bindings of $TAG are for ${bindings_num:-an unknown version}"
json_num="$(jq -r '.defines[] | select(.name == "IMGUI_VERSION_NUM") | .content' \
    "$TMP/dear_bindings/dcimgui_nodefaultargfunctions.json")"
[[ "$json_num" == "$IMGUI_VERSION_NUM" ]] ||
    die "dcimgui_nodefaultargfunctions.json is for ImGui version ${json_num:-unknown}, not $IMGUI_VERSION_NUM"

rm -rf "$REPO/upstream/imgui" "$REPO/upstream/dear_bindings"
mkdir -p "$REPO/upstream"
cp -R "$TMP/imgui" "$REPO/upstream/imgui"
cp -R "$TMP/dear_bindings" "$REPO/upstream/dear_bindings"
cat >"$VERSION_ENV" <<EOF
# The dear_bindings release and Dear ImGui sources in upstream/. Written by tools/update_imgui.sh.
DEAR_BINDINGS_TAG=$TAG
DEAR_BINDINGS_VERSION=$DEAR_BINDINGS_VERSION
IMGUI_TAG=$IMGUI_TAG
IMGUI_COMMIT=$IMGUI_COMMIT
IMGUI_VERSION_NUM=$IMGUI_VERSION_NUM
EOF
echo "Imported dear_bindings $DEAR_BINDINGS_VERSION and ImGui $IMGUI_TAG ($IMGUI_COMMIT)"

cd "$REPO"
if [[ $SOURCES_ONLY == 1 ]]; then
    exit 0
fi
"$ODIN" run tools/gen -out:tools/gen/gen.bin -- \
    upstream/dear_bindings/dcimgui_nodefaultargfunctions.json upstream/imconfig_odin.h \
    imgui/imgui_generated.odin tools/abi
if command -v "${CXX:-c++}" >/dev/null; then
    tools/build_imgui.sh
    tools/abi/check.sh
else
    echo "No C++ compiler: the library is not built and the ABI not checked"
fi
