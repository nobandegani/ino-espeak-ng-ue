#!/usr/bin/env bash
# setup-ios.sh
#
# Cross-compiles libespeak-ng.a for iOS device (arm64) from the vendored
# source via the iOS SDK shipped with Xcode, and stages the artifact into
# Source/ThirdParty/IOS/.
#
# Run once on a Mac with Xcode installed:
#     ./setup-ios.sh
#     ./setup-ios.sh --abi arm64-simulator   # iOS Simulator on Apple Silicon
#
# The platform-agnostic espeak-ng-data/ tree is copied once from the Win64
# build to Source/ThirdParty/IOS/espeak-ng-data/. setup-windows.ps1 must
# have run at least once first; the data tables are compiled by running
# espeak-ng-bin at host build time, and that can't be done while
# cross-compiling for iOS (the produced bin is an iOS arm64 binary the
# host Mac can't execute under Rosetta either).
#
# Why static (.a) and not a .framework / .dylib?
#   - iOS forbids dlopen of arbitrary dylibs; embedded frameworks add
#     code-signing and bundle-structure complexity for no benefit here.
#   - espeak-ng exposes a small, well-defined C API directly (no plugin
#     glob-scan like llama.cpp), so a static archive is the simplest
#     working integration.
#   - GPLv3 still applies; the surrounding game's licensing posture is
#     a project-level concern, not a plugin one.
#
# Requirements:
#   - macOS host (the iOS SDK is Xcode-only)
#   - Xcode (full install, not just Command Line Tools — the iOS SDK
#     and `xcodebuild` are both needed)
#   - CMake 3.13+ on PATH (3.13 is the first to ship a working
#     CMAKE_SYSTEM_NAME=iOS toolchain)
#   - setup-windows.ps1 has been run at least once on a Windows host
#     and the produced espeak-ng-data/ committed (provides the platform-
#     agnostic phoneme/dict tables)
#
# Outputs:
#   Source/ThirdParty/IOS/<abi>/libespeak-ng.a   (arch-specific static lib)
#   Source/ThirdParty/IOS/espeak-ng-data/         (shared, copied once)

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
ABI="arm64"          # arm64 (device) | arm64-simulator
IOS_DEPLOYMENT_TARGET="14.0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --abi)
            ABI="$2"
            shift 2
            ;;
        --deployment-target)
            IOS_DEPLOYMENT_TARGET="$2"
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
    arm64)
        SDK_NAME="iphoneos"
        OSX_ARCH="arm64"
        ;;
    arm64-simulator)
        SDK_NAME="iphonesimulator"
        OSX_ARCH="arm64"
        ;;
    *)
        echo "Unsupported --abi '$ABI'. Use arm64 or arm64-simulator." >&2
        exit 2
        ;;
esac

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESPEAKNG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$ESPEAKNG_DIR/vendor"
BUILD_DIR="$VENDOR_DIR/build-ios-$ABI"
THIRD_PARTY_DIR="$(cd "$ESPEAKNG_DIR/../Source/ThirdParty" && pwd)"

IOS_OUT_DIR="$THIRD_PARTY_DIR/IOS/$ABI"
WIN64_DATA_DIR="$THIRD_PARTY_DIR/Win64/espeak-ng-data"
# espeak-ng-data is platform-agnostic — same dictionaries / phoneme tables
# work for every iOS arch. Stage at a shared location (IOS/espeak-ng-data/,
# no arch subdir) so a multi-slice build doesn't duplicate ~3 MB per slice
# in the staged tree. Build.cs and the runtime extractor both read from
# this path.
IOS_DATA_DIR="$THIRD_PARTY_DIR/IOS/espeak-ng-data"

echo "espeak-ng 1.52.0 iOS $ABI build"
echo "  Vendor:       $VENDOR_DIR"
echo "  Build:        $BUILD_DIR"
echo "  ThirdParty:   $THIRD_PARTY_DIR"
echo

# ---------------------------------------------------------------------------
# Sanity-check host
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: setup-ios.sh must run on macOS — the iOS SDK is Xcode-only." >&2
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "ERROR: xcrun not found. Install Xcode (full install, not just" >&2
    echo "       Command Line Tools)." >&2
    exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "ERROR: cmake not found on PATH. Install via 'brew install cmake'" >&2
    echo "       and re-run." >&2
    exit 1
fi

# Resolve the SDK paths via xcrun. Fails loudly if Xcode isn't selected
# via 'xcode-select -s' (Command Line Tools alone don't ship the iOS SDK).
SDK_PATH="$(xcrun --sdk "$SDK_NAME" --show-sdk-path 2>/dev/null || true)"
if [[ -z "$SDK_PATH" ]] || [[ ! -d "$SDK_PATH" ]]; then
    echo "ERROR: '$SDK_NAME' SDK not found via xcrun." >&2
    echo "       Make sure Xcode is selected:" >&2
    echo "         sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

echo "  SDK:          $SDK_PATH"
echo "  Arch:         $OSX_ARCH"
echo "  Deployment:   iOS $IOS_DEPLOYMENT_TARGET"
echo

# ---------------------------------------------------------------------------
# Verify the Win64 data folder exists (we'll copy it as the iOS data)
# ---------------------------------------------------------------------------
if [[ ! -d "$WIN64_DATA_DIR" ]]; then
    cat >&2 <<EOM
ERROR: Win64 espeak-ng-data not found at
       $WIN64_DATA_DIR

The data tables must be compiled on the host first (espeak-ng-bin can't
run while cross-compiling for iOS). Run setup-windows.ps1 on a Windows
host first, commit the produced espeak-ng-data tree, then re-run this
script on the Mac.
EOM
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
# CMake's iOS support: setting CMAKE_SYSTEM_NAME=iOS triggers iOS cross-
# compile mode. CMAKE_OSX_SYSROOT points at the SDK and CMAKE_OSX_ARCHITECTURES
# pins the slice. We deliberately disable every espeak-ng feature that
# pulls in a host-side helper or audio backend — phonemization is the
# only call path the runtime ever takes (see InoSpeakNGBPLibrary::Phonemize).
# ---------------------------------------------------------------------------
echo "Configuring..."

cmake \
    -S "$VENDOR_DIR" \
    -B "$BUILD_DIR" \
    -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
    -DCMAKE_OSX_ARCHITECTURES="$OSX_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH=NO \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DUSE_MBROLA=OFF \
    -DUSE_LIBSONIC=OFF \
    -DUSE_LIBPCAUDIO=OFF \
    -DUSE_ASYNC=OFF \
    -DESPEAK_COMPAT=OFF \
    -DBUILD_TESTING=OFF

# ---------------------------------------------------------------------------
# Build ONLY the espeak-ng library target.
#
# Same reason as the Android build: the default `all` target tries to run
# espeak-ng-bin (the just-built CLI) to compile phoneme tables — and that's
# an iOS arm64 binary the host Mac can't execute. We use the Win64-built
# data tree instead.
# ---------------------------------------------------------------------------
echo
echo "Building (espeak-ng target only)..."
cmake --build "$BUILD_DIR" --config Release --target espeak-ng --parallel

# ---------------------------------------------------------------------------
# Stage outputs
# ---------------------------------------------------------------------------
echo
echo "Staging artifacts..."

# Locate the produced .a anywhere under the build dir. With the Xcode
# generator the path is typically
#     build-ios-arm64/src/libespeak-ng/Release-iphoneos/libespeak-ng.a
# but we don't hardcode the layout — find lets us absorb future CMake /
# Xcode generator changes.
LIB_PATH="$(find "$BUILD_DIR" -name "libespeak-ng.a" -type f | head -n 1 || true)"
if [[ -z "$LIB_PATH" ]]; then
    echo "ERROR: built libespeak-ng.a not found under $BUILD_DIR" >&2
    exit 1
fi

mkdir -p "$IOS_OUT_DIR"
cp -f "$LIB_PATH" "$IOS_OUT_DIR/libespeak-ng.a"

# Copy data from the Win64 build (platform-agnostic — same files work on iOS).
# Idempotent: replace any pre-existing copy outright.
rm -rf "$IOS_DATA_DIR"
mkdir -p "$IOS_DATA_DIR"
cp -R "$WIN64_DATA_DIR/." "$IOS_DATA_DIR/"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Done."
echo "  .a:      $IOS_OUT_DIR/libespeak-ng.a"
echo "  Data:    $IOS_DATA_DIR/"
