# setup-windows.ps1
#
# Builds espeak-ng 1.52.0 from the vendored source for Windows x64 and
# stages the resulting artifacts into Source/ThirdParty/. Run from
# anywhere; paths are resolved relative to this script.
#
# Requirements:
#   - CMake 3.8+ on PATH
#   - Visual Studio 2019/2022 with C++ workload installed
#     (CMake auto-detects the latest version)
#
# Outputs:
#   Source/ThirdParty/Win64/espeak-ng.dll
#   Source/ThirdParty/Win64/espeak-ng.lib
#   Source/ThirdParty/include/espeak-ng/*.h
#   Source/ThirdParty/Public/espeak-ng-data/

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$ScriptDir     = $PSScriptRoot
$EspeakNGDir   = Resolve-Path "$ScriptDir/.."
$VendorDir     = Resolve-Path "$EspeakNGDir/vendor"
$BuildDir      = Join-Path $VendorDir "build-win64"
$ThirdPartyDir = Resolve-Path "$EspeakNGDir/../Source/ThirdParty"

$Win64OutDir   = Join-Path $ThirdPartyDir "Win64"
$IncludeOutDir = Join-Path $ThirdPartyDir "include/espeak-ng"
$DataOutDir    = Join-Path $ThirdPartyDir "Public/espeak-ng-data"

Write-Host "espeak-ng 1.52.0 Win64 build" -ForegroundColor Cyan
Write-Host "  Vendor:       $VendorDir"
Write-Host "  Build:        $BuildDir"
Write-Host "  ThirdParty:   $ThirdPartyDir"
Write-Host ""

# ---------------------------------------------------------------------------
# Verify CMake on PATH
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
& cmake -S $VendorDir -B $BuildDir `
    -A x64 `
    -DCMAKE_BUILD_TYPE=Release `
    -DBUILD_SHARED_LIBS=ON `
    -DUSE_MBROLA=OFF `
    -DUSE_LIBSONIC=OFF `
    -DUSE_LIBPCAUDIO=OFF `
    -DUSE_ASYNC=OFF `
    -DESPEAK_COMPAT=OFF `
    -DBUILD_TESTING=OFF
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
Write-Host "`nBuilding..." -ForegroundColor Yellow
& cmake --build $BuildDir --config Release --parallel
if ($LASTEXITCODE -ne 0) { throw "CMake build failed" }

# ---------------------------------------------------------------------------
# Stage outputs
# ---------------------------------------------------------------------------
Write-Host "`nStaging artifacts..." -ForegroundColor Yellow

# Find the produced DLL + LIB anywhere under the build dir (they may sit in
# build-win64/src/Release/ or build-win64/src/libespeak-ng/Release/ depending
# on how RUNTIME/ARCHIVE output dirs are configured).
$Dll = Get-ChildItem -Path $BuildDir -Recurse -Filter "espeak-ng.dll" |
    Where-Object { $_.FullName -match "\\Release\\" } |
    Select-Object -First 1
$Lib = Get-ChildItem -Path $BuildDir -Recurse -Filter "espeak-ng.lib" |
    Where-Object { $_.FullName -match "\\Release\\" } |
    Select-Object -First 1

if (-not $Dll) { throw "Built espeak-ng.dll not found under $BuildDir" }
if (-not $Lib) { throw "Built espeak-ng.lib not found under $BuildDir" }

# Source data folder produced by the build
$BuiltDataDir = Join-Path $BuildDir "espeak-ng-data"
if (-not (Test-Path $BuiltDataDir)) {
    throw "Built espeak-ng-data dir not found at $BuiltDataDir"
}

# Make destination dirs
New-Item -ItemType Directory -Force -Path $Win64OutDir   | Out-Null
New-Item -ItemType Directory -Force -Path $IncludeOutDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $DataOutDir -Parent) | Out-Null

# Copy DLL + import lib
Copy-Item $Dll.FullName -Destination $Win64OutDir -Force
Copy-Item $Lib.FullName -Destination $Win64OutDir -Force

# Copy public headers from the source tree
Copy-Item "$VendorDir/src/include/espeak-ng/*.h" -Destination $IncludeOutDir -Force

# Replace any pre-existing staged data folder with the freshly compiled one
if (Test-Path $DataOutDir) {
    Remove-Item -Recurse -Force $DataOutDir
}
Copy-Item -Recurse $BuiltDataDir -Destination $DataOutDir -Force

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`nDone." -ForegroundColor Green
Write-Host "  DLL:     $Win64OutDir\espeak-ng.dll"
Write-Host "  LIB:     $Win64OutDir\espeak-ng.lib"
Write-Host "  Headers: $IncludeOutDir\"
Write-Host "  Data:    $DataOutDir\"
