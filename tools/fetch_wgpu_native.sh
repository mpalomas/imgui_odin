#!/usr/bin/env bash
# Downloads the wgpu-native libraries that vendor:wgpu links into $(odin root)/vendor/wgpu/lib/, for the
# examples. Odin ships them for macOS arm64 only: Linux needs them.
#
# Usage: tools/fetch_wgpu_native.sh
#
# The version is vendor:wgpu's BINDINGS_VERSION_STRING. The archive is checked against the SHA-256 digest
# GitHub lists for it.
# Environment:
#   ODIN      (default: odin from PATH, else ~/dev/odin/Odin/odin)
#   GH_TOKEN  Optional, for the GitHub API (its anonymous rate limit is 60 requests an hour)

set -euo pipefail

ODIN="${ODIN:-$(command -v odin || echo "$HOME/dev/odin/Odin/odin")}"

die() {
    echo "error: $*" >&2
    exit 1
}

for tool in curl jq unzip; do
    command -v "$tool" >/dev/null || die "$tool is required"
done

WGPU="$("$ODIN" root)/vendor/wgpu"
VERSION="$(sed -n 's/^BINDINGS_VERSION_STRING *:: *"\(.*\)"/\1/p' "$WGPU/wgpu_native_types.odin")"
[[ -n "$VERSION" ]] || die "no BINDINGS_VERSION_STRING in $WGPU/wgpu_native_types.odin"
case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    *) die "unsupported OS $(uname -s)" ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    arm64 | aarch64) arch=aarch64 ;;
    *) die "unsupported architecture $(uname -m)" ;;
esac
NAME="wgpu-$os-$arch-release"
DEST="$WGPU/lib/$NAME"
if [[ -f "$DEST/lib/libwgpu_native.a" ]]; then
    echo "$DEST has the libraries already"
    exit 0
fi

auth=()
if [[ -n "${GH_TOKEN:-}" ]]; then
    auth=(-H "Authorization: Bearer $GH_TOKEN")
fi
release="$(curl -fsSL --retry 3 ${auth[@]+"${auth[@]}"} "https://api.github.com/repos/gfx-rs/wgpu-native/releases/tags/v$VERSION")" ||
    die "no wgpu-native release v$VERSION"
asset="$(jq -c --arg f "$NAME.zip" '.assets[] | select(.name == $f)' <<<"$release")"
[[ -n "$asset" ]] || die "wgpu-native v$VERSION has no $NAME.zip"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading $NAME.zip of wgpu-native v$VERSION"
curl -fsSL --retry 3 -o "$TMP/$NAME.zip" "$(jq -r .browser_download_url <<<"$asset")"
want="$(jq -r '.digest // ""' <<<"$asset")"
if [[ "$want" == sha256:* ]]; then
    if command -v sha256sum >/dev/null; then
        got="$(sha256sum "$TMP/$NAME.zip" | cut -d ' ' -f 1)"
    else
        got="$(shasum -a 256 "$TMP/$NAME.zip" | cut -d ' ' -f 1)"
    fi
    [[ "$got" == "${want#sha256:}" ]] || die "checksum mismatch for $NAME.zip"
fi
mkdir -p "$DEST"
unzip -q -o "$TMP/$NAME.zip" -d "$DEST"
echo "Extracted to $DEST:"
ls -l "$DEST/lib"
