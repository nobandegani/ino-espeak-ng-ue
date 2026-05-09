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
# The platform-agnostic espeak-ng-data/ tree is copied once from a sibling
# native build (Win64 or Mac) to Source/ThirdParty/IOS/espeak-ng-data/.
# setup-windows.ps1 OR setup-macos.sh must have run at least once first;
# the data tables are compiled by running espeak-ng-bin at host build
# time, and that can't be done while cross-compiling for iOS (the
# produced bin is an iOS arm64 binary the host Mac can't execute, even
# under Rosetta). We prefer the Mac source when running on a Mac so a
# Mac-only workflow doesn't need a Windows checkout to bootstrap.
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
#     OR setup-macos.sh has been run on a Mac (either provides the
#     platform-agnostic phoneme/dict tables — they're identical regardless
#     of which host generated them)
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
# espeak-ng-data is platform-agnostic — same dictionaries / phoneme tables
# work for every iOS arch. Stage at a shared location (IOS/espeak-ng-data/,
# no arch subdir) so a multi-slice build doesn't duplicate ~3 MB per slice
# in the staged tree. Build.cs and the runtime extractor both read from
# this path.
IOS_DATA_DIR="$THIRD_PARTY_DIR/IOS/espeak-ng-data"

# Source dirs we'll consider as data origins, in preference order. Mac
# first because the user is already on a Mac to build for iOS — if they
# also ran setup-macos.sh in the same session, we want to use that fresh
# data rather than asking for a Windows-side bootstrap.
MAC_DATA_DIR="$THIRD_PARTY_DIR/Mac/espeak-ng-data"
WIN64_DATA_DIR="$THIRD_PARTY_DIR/Win64/espeak-ng-data"

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
# Resolve a data source — Mac preferred, Win64 as fallback
# ---------------------------------------------------------------------------
DATA_SRC_DIR=""
if [[ -d "$MAC_DATA_DIR" ]]; then
    DATA_SRC_DIR="$MAC_DATA_DIR"
elif [[ -d "$WIN64_DATA_DIR" ]]; then
    DATA_SRC_DIR="$WIN64_DATA_DIR"
fi

if [[ -z "$DATA_SRC_DIR" ]]; then
    cat >&2 <<EOM
ERROR: no espeak-ng-data found at
         $MAC_DATA_DIR
         $WIN64_DATA_DIR

The data tables must be compiled on a host that can execute the just-built
espeak-ng-bin (an iOS cross-compile produces an arm64 iOS binary the host
can't run). Pick one and re-run setup-ios.sh:
  - Mac:     ./setup-macos.sh
  - Windows: ./setup-windows.ps1   (commit the produced data tree, pull
                                    on the Mac, then re-run setup-ios.sh)
EOM
    exit 1
fi
echo "  Data source:  $DATA_SRC_DIR"

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

#  CMAKE_MACOSX_BUNDLE=OFF — on iOS, CMake defaults executables to
#    Application Bundle style (.app + Info.plist). espeak-ng's
#    src/CMakeLists.txt:34 runs `install(TARGETS espeak-ng-bin)`
#    without a BUNDLE DESTINATION, which fails the configure step
#    when bundle style is on. We don't ship espeak-ng-bin on iOS
#    anyway (the library target is all we need), so flipping the
#    bundle default off is the cleanest fix.
#
#  -DHAVE_SYS_ENDIAN_H — spect.c picks between <sys/endian.h> (when
#    HAVE_SYS_ENDIAN_H is set) and <endian.h>. The iOS SDK ships a
#    legacy Carbon header at /usr/include/Endian.h that the case-
#    insensitive default filesystem also resolves as <endian.h> —
#    that header doesn't expose le16toh / le32toh, so the build fails
#    with "call to undeclared function 'le16toh'". The compat shim at
#    src/include/compat/endian.h tries the system header first via
#    __has_include_next and gets the broken Carbon one. Forcing
#    HAVE_SYS_ENDIAN_H short-circuits the compat shim entirely; iOS
#    <sys/endian.h> does define the le16toh family.
#    macOS doesn't hit this — its SDK has no top-level endian.h, so
#    the compat shim correctly falls through to <sys/endian.h> on its
#    own.
cmake \
    -S "$VENDOR_DIR" \
    -B "$BUILD_DIR" \
    -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
    -DCMAKE_OSX_ARCHITECTURES="$OSX_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH=NO \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    -DCMAKE_C_FLAGS="-DHAVE_SYS_ENDIAN_H" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DUSE_MBROLA=OFF \
    -DUSE_LIBSONIC=OFF \
    -DUSE_LIBPCAUDIO=OFF \
    -DUSE_ASYNC=OFF \
    -DESPEAK_COMPAT=OFF \
    -DBUILD_TESTING=OFF

# ---------------------------------------------------------------------------
# Build the espeak-ng library target plus its sibling static archives
# (libucd, libspeechPlayer). With BUILD_SHARED_LIBS=OFF, CMake produces
# three separate .a files — libespeak-ng.a calls into the other two but
# their object files are NOT inside libespeak-ng.a. We merge them below
# into a single fat archive so UE only has to link one library.
#
# Same reason as the Android build for skipping the default `all` target:
# `all` tries to run espeak-ng-bin (the just-built CLI) to compile phoneme
# tables, and that's an iOS arm64 binary the host Mac can't execute. We
# use a sibling native build (Mac/Win64) for the data tree instead.
# ---------------------------------------------------------------------------
echo
echo "Building (espeak-ng + ucd + speechPlayer targets)..."
cmake --build "$BUILD_DIR" --config Release --target espeak-ng     --parallel
cmake --build "$BUILD_DIR" --config Release --target ucd           --parallel
cmake --build "$BUILD_DIR" --config Release --target speechPlayer  --parallel

# ---------------------------------------------------------------------------
# Stage outputs
# ---------------------------------------------------------------------------
echo
echo "Staging artifacts..."

# Locate the produced .a files anywhere under the build dir. With the
# Xcode generator the paths are typically
#     build-ios-arm64/src/libespeak-ng/Release-iphoneos/libespeak-ng.a
#     build-ios-arm64/src/ucd-tools/src/Release-iphoneos/libucd.a
#     build-ios-arm64/src/speechPlayer/Release-iphoneos/libspeechPlayer.a
# but we don't hardcode the layout — find lets us absorb future CMake /
# Xcode generator changes.
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
# libspeechPlayer.a is conditional on USE_SPEECHPLAYER, which is ON by
# default. If it's missing, we just don't merge it in — the espeak-ng
# library will only reference it when sPlayer.c was compiled in
# (USE_SPEECHPLAYER=ON), and that compile is what creates the .a in the
# first place, so its presence/absence is consistent with the symbols.
MERGE_INPUTS=("$ESPEAK_NG_LIB" "$UCD_LIB")
if [[ -n "$SPLAYER_LIB" ]]; then
    MERGE_INPUTS+=("$SPLAYER_LIB")
fi

mkdir -p "$IOS_OUT_DIR"
MERGED_LIB="$IOS_OUT_DIR/libespeak-ng.a"

# Merge with libtool -static: takes any number of input .a files and
# produces one .a containing every object from every input. macOS native
# (Xcode CLT ships it), idempotent (we always overwrite the dest).
echo "  Merging:"
for L in "${MERGE_INPUTS[@]}"; do echo "    $L"; done
echo "  -> $MERGED_LIB"
rm -f "$MERGED_LIB"
libtool -static -o "$MERGED_LIB" "${MERGE_INPUTS[@]}"

# Copy data from whichever native build is present (the files are
# platform-agnostic — same dictionaries / phoneme tables work on iOS).
# Idempotent: replace any pre-existing copy outright.
rm -rf "$IOS_DATA_DIR"
mkdir -p "$IOS_DATA_DIR"
cp -R "$DATA_SRC_DIR/." "$IOS_DATA_DIR/"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Done."
echo "  .a:      $IOS_OUT_DIR/libespeak-ng.a"
echo "  Data:    $IOS_DATA_DIR/"
