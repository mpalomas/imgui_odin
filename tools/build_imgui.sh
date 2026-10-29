#!/usr/bin/env bash
# Builds Dear ImGui and its C API (dear_bindings) from upstream/ into lib/<os>-<arch>/: libdcimgui.a,
# and libdcimgui.dylib (macOS) or libdcimgui.so (Linux).
#
# Usage: tools/build_imgui.sh [static|shared|all]   (default: all)
#
# Built with upstream/imconfig_odin.h, which the bindings are generated for. The objects are compiled
# once, position-independent, and serve both libraries. No exceptions, RTTI or thread-safe statics, so
# the libraries need the C library only, no C++ runtime: the script checks it. IM_ASSERT stays on, as
# ImGui recommends: it reports API misuse.
# Environment:
#   CXX                      (default: c++)
#   CC                       Links the shared library (default: cc)
#   CXXFLAGS                 Extra compiler flags
#   MACOSX_DEPLOYMENT_TARGET The oldest macOS to support (default: the compiler's)
#   JOBS                     Parallel compiles (default: the number of CPUs)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CXX="${CXX:-c++}"
CC="${CC:-cc}"
LINKAGE="${1:-all}"

die() {
    echo "error: $*" >&2
    exit 1
}

case "$LINKAGE" in
    static | shared | all) ;;
    *) die "usage: tools/build_imgui.sh [static|shared|all]" ;;
esac
case "$(uname -s)" in
    Linux) OS=linux SHARED_EXT=so ;;
    Darwin) OS=macos SHARED_EXT=dylib ;;
    *) die "unsupported OS $(uname -s)" ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) ARCH=x86_64 ;;
    arm64 | aarch64) ARCH=arm64 ;;
    *) die "unsupported architecture $(uname -m)" ;;
esac
PLATFORM="$OS-$ARCH"
LIB_DIR="$REPO/lib/$PLATFORM"
OBJ_DIR="$REPO/build/$PLATFORM"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

IMGUI="$REPO/upstream/imgui"
BINDINGS="$REPO/upstream/dear_bindings"
[[ -f "$IMGUI/imgui.cpp" && -f "$BINDINGS/dcimgui_nodefaultargfunctions.cpp" ]] ||
    die "no sources in upstream/: run tools/update_imgui.sh"
SOURCES=(
    "$IMGUI/imgui.cpp"
    "$IMGUI/imgui_draw.cpp"
    "$IMGUI/imgui_tables.cpp"
    "$IMGUI/imgui_widgets.cpp"
    "$IMGUI/imgui_demo.cpp"
    "$BINDINGS/dcimgui_nodefaultargfunctions.cpp"
)

# Only the C API is exported from the shared library. -ffunction-sections and -fdata-sections let the
# programs' linker drop the unused API (-Wl,--gc-sections, or -dead_strip on macOS).
FLAGS=(
    -std=c++11 -O2 -fPIC
    -fno-exceptions -fno-rtti -fno-threadsafe-statics
    -fvisibility=hidden -fvisibility-inlines-hidden
    -ffunction-sections -fdata-sections
    -I"$IMGUI" -I"$BINDINGS" -I"$REPO/upstream"
    '-DIMGUI_USER_CONFIG="imconfig_odin.h"'
    '-DCIMGUI_API=__attribute__((visibility("default")))'
)
# CXXFLAGS holds several flags.
# shellcheck disable=SC2206
FLAGS+=(${CXXFLAGS:-})

rm -rf "$OBJ_DIR"
mkdir -p "$OBJ_DIR" "$LIB_DIR"
echo "Compiling ${#SOURCES[@]} files with $("$CXX" --version | head -n 1)"
OBJECTS=()
pids=()
for src in "${SOURCES[@]}"; do
    obj="$OBJ_DIR/$(basename "${src%.cpp}").o"
    OBJECTS+=("$obj")
    while [[ $(jobs -rp | wc -l) -ge $JOBS ]]; do
        sleep 0.1
    done
    "$CXX" "${FLAGS[@]}" -c "$src" -o "$obj" &
    pids+=($!)
done
for pid in "${pids[@]}"; do
    wait "$pid" || die "compilation failed"
done

# Undefined symbols from the C++ runtime (libc++ or libstdc++): operator new/delete, __cxa_*, std::.
# __cxa_atexit and __cxa_finalize, which register static destructors, are in the C library.
cxx_runtime_symbols() {
    nm -u "$@" 2>/dev/null | awk '{ print $NF }' |
        grep -E '^_{1,2}(Znw|Zna|Zdl|Zda|cxa_|gxx_|ZNSt|ZSt)' | grep -vE '^_{1,2}cxa_(atexit|finalize)$' | sort -u || true
}
runtime="$(cxx_runtime_symbols "${OBJECTS[@]}")"
[[ -z "$runtime" ]] || die "the objects need the C++ runtime, which the bindings do not link:
$runtime"

if [[ "$LINKAGE" != shared ]]; then
    rm -f "$LIB_DIR/libdcimgui.a"
    ar rcs "$LIB_DIR/libdcimgui.a" "${OBJECTS[@]}"
fi
# Linked with the C compiler driver, which adds no C++ runtime (unlike c++ without -nostdlib++, which GCC
# only has since version 13).
if [[ "$LINKAGE" != static ]]; then
    out="$LIB_DIR/libdcimgui.$SHARED_EXT"
    if [[ "$OS" == macos ]]; then
        "$CC" -dynamiclib -install_name @rpath/libdcimgui.dylib -Wl,-dead_strip "${OBJECTS[@]}" -o "$out"
    else
        "$CC" -shared -Wl,-soname,libdcimgui.so -Wl,--gc-sections -Wl,--no-undefined "${OBJECTS[@]}" -lm -o "$out"
    fi
fi
echo "Built in lib/$PLATFORM/:"
ls -lh "$LIB_DIR"/libdcimgui.*
