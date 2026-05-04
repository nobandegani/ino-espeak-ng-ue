# setup-android.ps1
#
# Cross-compiles libespeak-ng.so for Android arm64-v8a from the vendored
# source via the Android NDK and stages the artifact into Source/ThirdParty/.
# Also copies the platform-agnostic espeak-ng-data/ from the Win64 build
# (must run setup-windows.ps1 first — the data is compiled by running
# espeak-ng-bin at build time and that can't be done while cross-compiling
# for arm64 on an x64 host).
#
# Requirements:
#   - Android NDK 27.2.12479018 installed (default; override via -NdkRoot)
#   - CMake 3.8+ on PATH
#   - Ninja somewhere on disk (auto-detected from Android Studio's CMake
#     bundle or Visual Studio's CMake tools; doesn't have to be on PATH)
#   - setup-windows.ps1 has been run at least once (provides espeak-ng-data/)
#
# Outputs:
#   Source/ThirdParty/Android/arm64-v8a/libespeak-ng.so
#   Source/ThirdParty/Android/arm64-v8a/espeak-ng-data/

[CmdletBinding()]
param(
    [string]$NdkRoot,
    [string]$NdkVersion = "27.2.12479018",
    [int]$AndroidApi    = 30,
    [string]$AndroidAbi = "arm64-v8a",
    [string]$AndroidStl = "c++_static"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$ScriptDir     = $PSScriptRoot
$EspeakNGDir   = Resolve-Path "$ScriptDir/.."
$VendorDir     = Resolve-Path "$EspeakNGDir/vendor"
$BuildDir      = Join-Path $VendorDir "build-android-$AndroidAbi"
$ThirdPartyDir = Resolve-Path "$EspeakNGDir/../Source/ThirdParty"

$AndroidOutDir   = Join-Path $ThirdPartyDir "Android/$AndroidAbi"
$Win64DataDir    = Join-Path $ThirdPartyDir "Win64/espeak-ng-data"
$AndroidDataDir  = Join-Path $AndroidOutDir "espeak-ng-data"

Write-Host "espeak-ng 1.52.0 Android $AndroidAbi build" -ForegroundColor Cyan
Write-Host "  Vendor:       $VendorDir"
Write-Host "  Build:        $BuildDir"
Write-Host "  ThirdParty:   $ThirdPartyDir"
Write-Host ""

# ---------------------------------------------------------------------------
# Locate the NDK
# ---------------------------------------------------------------------------
function Resolve-NdkRoot {
    param([string]$Explicit, [string]$WantedVersion)

    # Explicit override wins
    if ($Explicit) {
        if (-not (Test-Path $Explicit)) {
            throw "NdkRoot '$Explicit' does not exist."
        }
        return (Resolve-Path $Explicit).Path
    }

    # Then env vars
    foreach ($v in @($env:ANDROID_NDK_HOME, $env:ANDROID_NDK_ROOT, $env:NDKROOT)) {
        if ($v -and (Test-Path $v)) { return (Resolve-Path $v).Path }
    }

    # Then the standard Android Studio install path with the wanted version
    $StudioPath = Join-Path $env:LOCALAPPDATA "Android/Sdk/ndk/$WantedVersion"
    if (Test-Path $StudioPath) { return (Resolve-Path $StudioPath).Path }

    # Then NVPACK (UE's Android Studio bundle)
    $NvpackBase = "C:/NVPACK"
    if (Test-Path $NvpackBase) {
        $nvpackNdk = Get-ChildItem $NvpackBase -Directory -Filter "android-ndk-*" |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($nvpackNdk) { return $nvpackNdk.FullName }
    }

    throw @"
Android NDK $WantedVersion not found.
Looked in:
  - `$env:ANDROID_NDK_HOME / `$env:ANDROID_NDK_ROOT / `$env:NDKROOT
  - $StudioPath
  - C:\NVPACK\android-ndk-*\
Install via Android Studio (SDK Manager > SDK Tools > NDK) or pass an explicit path:
  ./setup-android.ps1 -NdkRoot 'C:\path\to\ndk\$WantedVersion'
"@
}

$NdkRoot = Resolve-NdkRoot -Explicit $NdkRoot -WantedVersion $NdkVersion
$ToolchainFile = Join-Path $NdkRoot "build/cmake/android.toolchain.cmake"
if (-not (Test-Path $ToolchainFile)) {
    throw "NDK toolchain file not found at $ToolchainFile (NdkRoot may be invalid)."
}

# ---------------------------------------------------------------------------
# Locate Ninja — required by the NDK toolchain. Most dev machines have it
# bundled (Android Studio's CMake or Visual Studio's CMake tools); we don't
# require it on PATH.
# ---------------------------------------------------------------------------
function Resolve-Ninja {
    # 1. On PATH
    $cmd = Get-Command ninja -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }

    # 2. Android Studio's CMake bundle (uses the highest installed CMake)
    $studioCmakeBase = Join-Path $env:LOCALAPPDATA "Android/Sdk/cmake"
    if (Test-Path $studioCmakeBase) {
        $latest = Get-ChildItem $studioCmakeBase -Directory |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($latest) {
            $candidate = Join-Path $latest.FullName "bin/ninja.exe"
            if (Test-Path $candidate) { return $candidate }
        }
    }

    # 3. Visual Studio's bundled Ninja (any 2019+ install)
    $vsBases = @(
        "C:/Program Files/Microsoft Visual Studio/2022/Community",
        "C:/Program Files/Microsoft Visual Studio/2022/Professional",
        "C:/Program Files/Microsoft Visual Studio/2022/Enterprise",
        "C:/Program Files (x86)/Microsoft Visual Studio/2019/Community",
        "C:/Program Files (x86)/Microsoft Visual Studio/2019/Professional",
        "C:/Program Files (x86)/Microsoft Visual Studio/2019/Enterprise"
    )
    foreach ($base in $vsBases) {
        $candidate = Join-Path $base "Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja/ninja.exe"
        if (Test-Path $candidate) { return $candidate }
    }

    throw @"
ninja not found.
Looked on PATH and in:
  - $studioCmakeBase\<version>\bin\ninja.exe (Android Studio CMake)
  - <VS install>\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe
Install it via the Android Studio SDK Manager (SDK Tools > CMake) or
'winget install Ninja-build.Ninja', then re-run.
"@
}
$NinjaExe = Resolve-Ninja

Write-Host "  NDK:          $NdkRoot"
Write-Host "  ABI:          $AndroidAbi"
Write-Host "  API:          android-$AndroidApi"
Write-Host "  STL:          $AndroidStl"
Write-Host "  Ninja:        $NinjaExe"
Write-Host ""

# ---------------------------------------------------------------------------
# Verify the Win64 data folder exists (we'll copy it as the Android data)
# ---------------------------------------------------------------------------
if (-not (Test-Path $Win64DataDir)) {
    throw @"
Win64 espeak-ng-data not found at $Win64DataDir.
The data tables must be compiled on the host first (espeak-ng-bin can't run
while cross-compiling for arm64). Run setup-windows.ps1 first, then re-run
this script.
"@
}

# ---------------------------------------------------------------------------
# Verify CMake
# ---------------------------------------------------------------------------
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    throw "cmake not found on PATH. Install CMake 3.8+ and re-run."
}

# ---------------------------------------------------------------------------
# Clean prior build output (keeps the script idempotent)
# ---------------------------------------------------------------------------
if (Test-Path $BuildDir) {
    Write-Host "Removing existing build dir..." -ForegroundColor DarkGray
    Remove-Item -Recurse -Force $BuildDir
}

# ---------------------------------------------------------------------------
# Configure
# ---------------------------------------------------------------------------
Write-Host "Configuring..." -ForegroundColor Yellow

# Build the cmake argument list explicitly so PowerShell's parser doesn't
# mangle `=$Var` constructs across backtick continuations. Each -D flag is a
# single argument string we control precisely.
$cmakeArgs = @(
    "-S", $VendorDir,
    "-B", $BuildDir,
    "-G", "Ninja",
    "-DCMAKE_MAKE_PROGRAM=$NinjaExe",
    "-DCMAKE_TOOLCHAIN_FILE=$ToolchainFile",
    "-DANDROID_ABI=$AndroidAbi",
    "-DANDROID_PLATFORM=android-$AndroidApi",
    "-DANDROID_STL=$AndroidStl",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DBUILD_SHARED_LIBS=ON",
    "-DUSE_MBROLA=OFF",
    "-DUSE_LIBSONIC=OFF",
    "-DUSE_LIBPCAUDIO=OFF",
    "-DUSE_ASYNC=OFF",
    "-DESPEAK_COMPAT=OFF",
    "-DBUILD_TESTING=OFF"
)
& cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

# ---------------------------------------------------------------------------
# Build ONLY the espeak-ng library target.
#
# We deliberately avoid the default `all` target because espeak-ng's `data`
# target tries to run espeak-ng-bin (the just-built CLI) to compile phoneme
# tables — and that's an arm64 binary the x64 host can't execute.
# ---------------------------------------------------------------------------
Write-Host "`nBuilding (espeak-ng target only)..." -ForegroundColor Yellow
& cmake --build $BuildDir --target espeak-ng --parallel
if ($LASTEXITCODE -ne 0) { throw "CMake build failed" }

# ---------------------------------------------------------------------------
# Stage outputs
# ---------------------------------------------------------------------------
Write-Host "`nStaging artifacts..." -ForegroundColor Yellow

# Locate the produced .so anywhere under the build dir
$So = Get-ChildItem -Path $BuildDir -Recurse -Filter "libespeak-ng.so" |
    Select-Object -First 1
if (-not $So) { throw "Built libespeak-ng.so not found under $BuildDir" }

New-Item -ItemType Directory -Force -Path $AndroidOutDir | Out-Null

# Copy .so
Copy-Item $So.FullName -Destination $AndroidOutDir -Force

# Copy data from the Win64 build (platform-agnostic — same files work on Android)
if (Test-Path $AndroidDataDir) {
    Remove-Item -Recurse -Force $AndroidDataDir
}
Copy-Item -Recurse $Win64DataDir -Destination $AndroidDataDir -Force

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`nDone." -ForegroundColor Green
Write-Host "  .so:     $AndroidOutDir\libespeak-ng.so"
Write-Host "  Data:    $AndroidDataDir\"
