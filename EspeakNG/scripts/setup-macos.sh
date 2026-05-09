#!/usr/bin/env bash
# setup-macos.sh
#
# Builds libespeak-ng.a for macOS (universal arm64 + x86_64) and the
# espeak-ng-data tree from the vendored source, then stages both into
# Source/ThirdParty/Mac/.
#
# Run on a Mac with Xcode (or just the Command Line Tools) installed:
#     ./setup-macos.sh                          # universal (arm64 + x86_64)
#     ./setup-macos.sh --abi arm64              # Apple Silicon only
#     ./setup-macos.sh --abi x86_64             # Intel only
#
# Unlike setup-ios.sh, this script also runs espeak-ng-bin natively to
# generate espeak-ng-data/ from scratch — the host Mac can execute the
# just-built CLI directly. So a Mac is fully self-sufficient: it doesn't
# need Win64's data tree to be staged first.
#
# Why static (.a) and not a dylib?
#   - Mirrors the iOS integration (single compiled-in archive, no
#     dynamic-loader configuration on launch).
#   - macOS apps CAN load dylibs, but the surrounding code is set up to
#     resolve espeak symbols at link time (Win64 uses an import lib +
#     DLL combo specifically because Windows requires it; everywhere
#     else there's no upside to a separate dylib).
#
# Requirements:
#   - macOS host
#   - Xcode (full install) OR Xcode Command Line Tools — clang +
#     macOS SDK either way
#   - CMake 3.13+ on PATH (3.13 is the first that handles
#     CMAKE_OSX_ARCHITECTURES universal builds cleanly with Xcode 11+)
#
# Outputs:
#   Source/ThirdParty/Mac/libespeak-ng.a    (universal or single-arch)
#   Source/ThirdParty/Mac/espeak-ng-data/   (freshly generated)

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
ABI="universal"        # universal (arm64+x86_64) | arm64 | x86_64
MAC_DEPLOYMENT_TARGET="11.0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --abi)
            ABI="$2"
            shift 2
            ;;
        --deployment-target)
            MAC_DEPLOYMENT_TARGET="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

case "$ABI" in
    universal)
        OSX_ARCHITECTURES="arm64;x86_64"
        ;;
    arm64)
        OSX_ARCHITECTURES="arm64"
        ;;
    x86_64)
        OSX_ARCHITECTURES="x86_64"
        ;;
    *)
        echo "Unsupported --abi '$ABI'. Use universal, arm64, or x86_64." >&2
        exit 2
        ;;
esac

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESPEAKNG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$ESPEAKNG_DIR/vendor"
BUILD_DIR="$VENDOR_DIR/build-macos-$ABI"
THIRD_PARTY_DIR="$(cd "$ESPEAKNG_DIR/../Source/ThirdParty" && pwd)"

MAC_OUT_DIR="$THIRD_PARTY_DIR/Mac"
MAC_DATA_DIR="$THIRD_PARTY_DIR/Mac/espeak-ng-data"

echo "espeak-ng 1.52.0 macOS $ABI build"
echo "  Vendor:       $VENDOR_DIR"
echo "  Build:        $BUILD_DIR"
echo "  ThirdParty:   $THIRD_PARTY_DIR"
echo "  Arch:         $OSX_ARCHITECTURES"
echo "  Deployment:   macOS $MAC_DEPLOYMENT_TARGET"
echo

# ---------------------------------------------------------------------------
# Sanity-check host
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: setup-macos.sh must run on macOS." >&2
    exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "ERROR: cmake not found on PATH. Install via 'brew install cmake'" >&2
    echo "       and re-run." >&2
    exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
    echo "ERROR: clang not found. Install Xcode or 'xcode-select --install'." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Clean prior build output (keeps the script idempotent)
# ---------------------------------------------------------------------------
if [[ -d "$BUILD_DIR" ]]; then
    echo "Removing existing build dir..."
    rm -rf "$BUILD_DIR"
fi

# ---------------------------------------------------------------------------
# Configure
#
# Mac is a native build (not cross-compile), so we don't set
# CMAKE_SYSTEM_NAME — CMake auto-detects Darwin. CMAKE_OSX_ARCHITECTURES
# drives the slice(s); a `;`-separated list yields a universal binary
# in a single pass (clang invoked once per arch via -arch flags).
#
# Default (`all`) target builds espeak-ng + the espeak-ng-bin CLI + runs
# espeak-ng-bin to compile the data tables. That last step IS executable
# on the host Mac (unlike Android / iOS cross-compiles), so we get a
# fresh espeak-ng-data/ tree with no Win64 dependency.
# ---------------------------------------------------------------------------
echo "Configuring..."

cmake \
    -S "$VENDOR_DIR" \
    -B "$BUILD_DIR" \
    -DCMAKE_OSX_ARCHITECTURES="$OSX_ARCHITECTURES" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MAC_DEPLOYMENT_TARGET" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DUSE_MBROLA=OFF \
    -DUSE_LIBSONIC=OFF \
    -DUSE_LIBPCAUDIO=OFF \
    -DUSE_ASYNC=OFF \
    -DESPEAK_COMPAT=OFF \
    -DBUILD_TESTING=OFF

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
echo
echo "Building..."
cmake --build "$BUILD_DIR" --config Release --parallel

# ---------------------------------------------------------------------------
# Stage outputs
#
# espeak-ng's static build produces three separate archives:
#   libespeak-ng.a        — the main library
#   libucd.a              — Unicode character DB helpers (ucd-tools/)
#   libspeechPlayer.a     — Klatt-style speech synthesizer (speechPlayer/)
# libespeak-ng.a calls into the other two, but their object files are
# NOT inside it. We merge them with `libtool -static` so UE only has to
# link one library and won't hit "Undefined symbols: _ucd_*,
# _speechPlayer_*" at the final link step.
# ---------------------------------------------------------------------------
echo
echo "Staging artifacts..."

ESPEAK_NG_LIB="$(find "$BUILD_DIR" -name "libespeak-ng.a"     -type f | head -n 1 || true)"
UCD_LIB="$(       find "$BUILD_DIR" -name "libucd.a"          -type f | head -n 1 || true)"
SPLAYER_LIB="$(   find "$BUILD_DIR" -name "libspeechPlayer.a" -type f | head -n 1 || true)"

if [[ -z "$ESPEAK_NG_LIB" ]]; then
    echo "ERROR: built libespeak-ng.a not found under $BUILD_DIR" >&2
    exit 1
fi
if [[ -z "$UCD_LIB" ]]; then
    echo "ERROR: built libucd.a not found under $BUILD_DIR" >&2
    exit 1
fi
# libspeechPlayer.a is conditional on USE_SPEECHPLAYER (ON by default).
# Only merge it when actually present.
MERGE_INPUTS=("$ESPEAK_NG_LIB" "$UCD_LIB")
if [[ -n "$SPLAYER_LIB" ]]; then
    MERGE_INPUTS+=("$SPLAYER_LIB")
fi

BUILT_DATA_DIR="$BUILD_DIR/espeak-ng-data"
if [[ ! -d "$BUILT_DATA_DIR" ]]; then
    echo "ERROR: built espeak-ng-data not found at $BUILT_DATA_DIR" >&2
    exit 1
fi

mkdir -p "$MAC_OUT_DIR"
MERGED_LIB="$MAC_OUT_DIR/libespeak-ng.a"

echo "  Merging:"
for L in "${MERGE_INPUTS[@]}"; do echo "    $L"; done
echo "  -> $MERGED_LIB"
rm -f "$MERGED_LIB"
libtool -static -o "$MERGED_LIB" "${MERGE_INPUTS[@]}"

# Replace any pre-existing staged data folder with the freshly compiled one
rm -rf "$MAC_DATA_DIR"
mkdir -p "$MAC_DATA_DIR"
cp -R "$BUILT_DATA_DIR/." "$MAC_DATA_DIR/"

# Verify the universal slices are what we expect (only when --abi=universal)
if [[ "$ABI" == "universal" ]]; then
    if command -v lipo >/dev/null 2>&1; then
        echo
        echo "Slices in $MAC_OUT_DIR/libespeak-ng.a:"
        lipo -info "$MAC_OUT_DIR/libespeak-ng.a"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Done."
echo "  .a:      $MAC_OUT_DIR/libespeak-ng.a"
echo "  Data:    $MAC_DATA_DIR/"
