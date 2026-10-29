#!/usr/bin/env bash
# Downloads the prebuilt Dear ImGui libraries that match the committed bindings into lib/<os>-<arch>/, from
# the GitHub release named in upstream/release.env (written by .github/workflows/build-imgui.yml).
#
# Usage: tools/fetch_imgui_libs.sh [PLATFORM...]
#   PLATFORM  linux-x86_64 or macos-arm64 (default: this machine's)
#
# Checks the release's dear_bindings header and imconfig_odin.h against the committed ones, and the
# downloads against the release's SHA256SUMS. Uses gh when it is installed and logged in, else curl.
# Environment:
#   IMGUI_RELEASE_REPO  (default: mpalomas/imgui_odin)
#   IMGUI_RELEASE_URL   Base URL of the release downloads, for curl (default: the repository's releases)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLUG="${IMGUI_RELEASE_REPO:-mpalomas/imgui_odin}"
BASE_URL="${IMGUI_RELEASE_URL:-https://github.com/$SLUG/releases/download}"
PIN="$REPO/upstream/release.env"
HEADER=dcimgui_nodefaultargfunctions.h

die() {
    echo "error: $*" >&2
    exit 1
}

[[ -f "$PIN" ]] || die "no $PIN: the committed bindings do not come from a release. Build the library with tools/build_imgui.sh"
TAG="$(sed -n 's/^RELEASE_TAG=//p' "$PIN")"
[[ -n "$TAG" ]] || die "no RELEASE_TAG in $PIN"

if [[ $# -gt 0 ]]; then
    PLATFORMS=("$@")
else
    case "$(uname -s)" in
        Linux) os=linux ;;
        Darwin) os=macos ;;
        *) die "unsupported OS $(uname -s)" ;;
    esac
    case "$(uname -m)" in
        x86_64 | amd64) arch=x86_64 ;;
        arm64 | aarch64) arch=arm64 ;;
        *) die "unsupported architecture $(uname -m)" ;;
    esac
    PLATFORMS=("$os-$arch")
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FILES=("$HEADER" imconfig_odin.h SHA256SUMS)
for platform in "${PLATFORMS[@]}"; do
    FILES+=("dcimgui-$platform.tar.gz")
done

echo "Downloading ${FILES[*]} from release $TAG of $SLUG"
if [[ -z "${IMGUI_RELEASE_URL:-}" ]] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    patterns=()
    for f in "${FILES[@]}"; do
        patterns+=(--pattern "$f")
    done
    gh release download "$TAG" --repo "$SLUG" --dir "$TMP" "${patterns[@]}"
else
    for f in "${FILES[@]}"; do
        curl -fsSL --retry 3 -o "$TMP/$f" "$BASE_URL/$TAG/$f" || die "cannot download $f"
    done
fi
for f in "${FILES[@]}"; do
    [[ -f "$TMP/$f" ]] || die "release $TAG has no $f"
done

sha256() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}
for f in "${FILES[@]}"; do
    [[ "$f" != SHA256SUMS ]] || continue
    want="$(awk -v f="$f" '$2 == f || $2 == "*" f { print $1 }' "$TMP/SHA256SUMS")"
    [[ -n "$want" ]] || die "$f is not in the release's SHA256SUMS"
    [[ "$(sha256 "$TMP/$f")" == "$want" ]] || die "checksum mismatch for $f"
done

# The library must be the ImGui version and configuration the bindings were generated for.
cmp -s "$TMP/$HEADER" "$REPO/upstream/dear_bindings/$HEADER" ||
    die "upstream/dear_bindings/$HEADER differs from release $TAG's: the bindings were updated since. Build the library with tools/build_imgui.sh"
cmp -s "$TMP/imconfig_odin.h" "$REPO/upstream/imconfig_odin.h" ||
    die "upstream/imconfig_odin.h differs from release $TAG's: the configuration changed since. Build the library with tools/build_imgui.sh"

for platform in "${PLATFORMS[@]}"; do
    # The archives hold lib/<platform>/libdcimgui.*.
    tar -xzf "$TMP/dcimgui-$platform.tar.gz" -C "$REPO"
    echo "Extracted to lib/$platform/:"
    ls -lh "$REPO/lib/$platform/"
done
