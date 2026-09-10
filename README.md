# InoSpeakNG

**Text-to-IPA phonemization for Unreal Engine 5**, backed by
[eSpeak NG](https://github.com/espeak-ng/espeak-ng). One Blueprint node in, IPA phonemes out —
on Windows, Android, iOS and macOS.

It exists to feed neural TTS models. Most voice-cloning and speech-synthesis pipelines want IPA
rather than raw text, and eSpeak NG is the standard way to get it. This plugin makes that a
single Blueprint call inside the game process — no Python, no subprocess, no network.

> ### ⚠️ This plugin is GPL-3.0, and that is not a formality
>
> eSpeak NG is licensed **GPL-3.0**, this plugin links it, and it ships **prebuilt eSpeak NG
> binaries for every supported platform**. On **iOS and macOS it is linked statically**, meaning
> eSpeak NG's object code is baked directly into your shipped executable.
>
> If you ship a game that includes this plugin, GPL-3.0 obligations attach to what you ship.
> **Read [Licensing](#licensing) before you build anything on this.** It is the most important
> section in this README.

---

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Install](#install)
- [Build the native library](#build-the-native-library)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Platform support](#platform-support)
- [Troubleshooting](#troubleshooting)
- [Licensing](#licensing)

---

## What it does

The entire public API is two functions:

| Node | Signature | Returns |
|---|---|---|
| **Phonemize Text (IPA)** | `Phonemize(Text, LanguageCode = "en-us")` | IPA phonemes as a UTF-8 `FString`, or empty on failure |
| **Is Available** | `IsAvailable()` | `true` if eSpeak NG initialized at module startup |

That is deliberately the whole surface. eSpeak NG can also synthesize audio; this plugin does
not expose that, and the bundled library is built with `USE_LIBPCAUDIO=OFF` so no audio backend
is compiled in at all. Phonemization is pure CPU work — no audio device, no system services, no
entitlements.

Around 100 languages are supported. The language code is an eSpeak voice name (`en-us`, `de`,
`fr-fr`, `es`, `ar`, `cmn`, …); the full list is whatever is in `espeak-ng-data/voices/`.

---

## Requirements

- **Unreal Engine 5** (developed against 5.7)
- Per-platform native toolchain to build eSpeak NG once — see
  [Build the native library](#build-the-native-library)

> **⚠️ Android is the exception: its libraries are not committed.** The previously committed
> `libespeak-ng.so` files embedded absolute build paths (espeak-ng's assert macros expand
> `__FILE__`, and a Release build keeps them), so they were removed. **Run
> `EspeakNG/scripts/setup-android.ps1` to rebuild them** — the script now passes
> `-ffile-prefix-map`, so the result is clean. `Build.cs` guards the path with `File.Exists`, so
> until you do, the plugin still compiles and `IsAvailable()` simply returns `false` on Android.

Prebuilt libraries for Win64, iOS and Mac are committed under `Source/ThirdParty/`, so
for those platforms a clean checkout builds without running anything. Rebuild only when you
want to move the eSpeak NG pin.

---

## Install

This repo uses a **git submodule** for eSpeak NG's source, so clone recursively:

```bash
cd YourProject/Plugins
git clone --recurse-submodules https://github.com/nobandegani/ino-espeak-ng-ue.git InoSpeakNG
```

Already cloned without it?

```bash
git submodule update --init --recursive
```

Then add `InoSpeakNG` to your `.uproject` `Plugins` array, regenerate project files, and build.

> The submodule holds eSpeak NG's **source**. It is not needed to compile the plugin — the
> prebuilt libraries are committed — but it is what the setup scripts build from, and it is the
> corresponding source that GPL-3.0 §6 requires be available alongside the binaries. Keep it.

---

## Build the native library

Only needed to change the eSpeak NG version or add a platform. Scripts live in
`EspeakNG/scripts/` and stage their output into `Source/ThirdParty/`.

| Script | Host | Produces |
|---|---|---|
| `setup-windows.ps1` | Windows | `Win64/espeak-ng.{dll,lib}` + `Win64/espeak-ng-data/` |
| `setup-android.ps1` | Windows | `Android/<abi>/libespeak-ng.so` + shared `Android/espeak-ng-data/` |
| `setup-ios.sh` | macOS + Xcode | `IOS/arm64/libespeak-ng.a` + `IOS/espeak-ng-data/` |
| `setup-macos.sh` | macOS | `Mac/libespeak-ng.a` (universal) + `Mac/espeak-ng-data/` |

**Order matters.** `espeak-ng-data` is compiled by *running* `espeak-ng-bin` on the host, which
is impossible while cross-compiling. So a native build must go first to produce the data
tables, and the cross-compile scripts copy them:

```bash
# Windows-centric workflow
./setup-windows.ps1                      # first — produces the data tables
./setup-android.ps1                      # arm64-v8a (default)
./setup-android.ps1 -AndroidAbi x86_64   # emulators / x86 Chromebooks

# Mac-centric workflow
./setup-macos.sh                         # first — produces the data tables
./setup-ios.sh                           # arm64 device
./setup-ios.sh --abi arm64-simulator     # optional; needs manual Build.cs wiring
```

Android defaults to NDK `27.2.12479018`, API 30, `c++_static` — override with `-NdkRoot`,
`-NdkVersion`, `-AndroidApi`, `-AndroidAbi`, `-AndroidStl`.

After changing the bundled data, bump `kEspeakDataStamp` in
[`InoSpeakNG.cpp`](Source/InoSpeakNG/Private/InoSpeakNG.cpp) so mobile clients re-extract
instead of reusing a stale copy.

---

## Usage

### Blueprint

Search for **"Phonemize"** in any Blueprint graph. Feed it a string, optionally set the
language code, read the IPA out. Gate on **Is Available** if you want to degrade gracefully
when the native library or data tree is missing.

### C++

Add `InoSpeakNG` to your module's dependencies, then:

```cpp
#include "InoSpeakNGBPLibrary.h"

if (UInoSpeakNGBPLibrary::IsAvailable())
{
    const FString Ipa = UInoSpeakNGBPLibrary::Phonemize(
        TEXT("Hello, traveller."), TEXT("en-us"));
    // Ipa == "həlˈoʊ tɹˈavələ"  (approximately — exact output is version-dependent)
}
```

> **Not thread-safe.** eSpeak NG keeps internal static buffers and the returned string lives in
> one of them, so call `Phonemize` from one thread at a time. The Blueprint VM is
> single-threaded, so the default game-thread call site is safe. If you phonemize from a worker
> thread, serialize the calls yourself.

Multi-clause input is handled for you: eSpeak NG processes one clause per call, so `Phonemize`
loops until the input is exhausted and joins the clauses with single spaces.

---

## How it works

```
StartupModule  (LoadingPhase: PreLoadingScreen)
      │
      ├─ ResolveDataParentPath()
      │     desktop  → probe 4 known layouts for espeak-ng-data/
      │     mobile   → extract it out of the pak to a writable path
      │
      ├─ ConvertToAbsolutePathForExternalAppForRead()
      │     espeak-ng uses raw fopen(), which cannot resolve UE's
      │     "../../../Project/..." relative paths
      │
      └─ espeak_Initialize(AUDIO_OUTPUT_RETRIEVAL, 0, path, 0)
```

Two details account for most of the platform-specific code:

**eSpeak NG reads its data with raw `fopen()`.** It has no hook for UE's virtual filesystem and
no Android `AAssetManager` integration upstream. On desktop that is fine — the data sits next to
the binaries as loose files. On Android and iOS the data is cooked into the pak, where `fopen()`
cannot reach it, so on first run the module copies the tree out to
`FPaths::ProjectPersistentDownloadDir()/ino-speak-ng/` via `IFileManager` (which *can* read the
pak). A stamp file makes this idempotent; the stamp is written only after a complete copy, so an
interrupted extraction self-heals on the next launch.

**The data tables are platform-agnostic but staged per-platform,** so cooking for one platform
does not drag in another's copy. Same ~364 files, four staging directories.

`LoadingPhase` is `PreLoadingScreen` so `espeak_Initialize` has completed before any dependent
plugin's `StartupModule` runs.

---

## Platform support

| Platform | Linkage | Artifact | Data at runtime |
|---|---|---|---|
| **Win64** | Dynamic | `espeak-ng.dll` + import lib | Loose files beside the binaries |
| **Android** (arm64-v8a, x86_64) | Dynamic | `libespeak-ng.so`, `DT_NEEDED` + UPL `System.loadLibrary` | Extracted from pak on first run |
| **iOS** (arm64 device) | **Static** | `libespeak-ng.a` linked into the executable | Extracted from pak on first run |
| **macOS** (universal) | **Static** | `libespeak-ng.a` (arm64 + x86_64) | Loose files in the `.app` bundle |

The static `.a` files are deliberately **not** added to `RuntimeDependencies` — staging a bare
library inside an `.app` bundle fails App Store validation with "Invalid bundle structure".

Every platform is `File.Exists`-guarded in `Build.cs`, so a checkout missing a given platform's
library still configures and compiles; `IsAvailable()` simply returns `false` at runtime. On any
platform other than these four, the module loads and reports unavailable rather than failing the
build.

---

## Troubleshooting

Everything logs under the **`LogInoSpeakNG`** category, and the data-path probe logs every
candidate it tries with `FOUND` / `missing` — start there.

| Symptom | Cause |
|---|---|
| `Could not locate espeak-ng-data` | The data tree was never staged. Run the matching `setup-*` script. |
| `espeak_Initialize failed (returned -1)` | Data directory found but unreadable or incomplete — check the absolute path in the log right above. |
| `Phonemize called but espeak-ng is not initialized` | Startup failed earlier; scroll up for the real error. |
| `espeak_SetVoiceByName failed for language 'xx'` | Not a valid eSpeak voice name. Check `espeak-ng-data/voices/`. |
| Works in editor, fails packaged | The cook did not stage `espeak-ng-data`. Verify the `RuntimeDependencies` entries in `Build.cs`. |
| Mobile: worked once, broke after an update | Bump `kEspeakDataStamp` so the stale extracted copy is replaced. |

---

## Licensing

### This plugin is GPL-3.0

See [`LICENSE`](LICENSE). Every source file in `Source/InoSpeakNG/` carries a matching
GPL-3.0 header.

This is not a choice so much as a consequence. eSpeak NG is GPL-3.0, and this repository:

- **links** eSpeak NG into the module on every supported platform, and
- **redistributes prebuilt eSpeak NG binaries** — `Win64/espeak-ng.dll`, `Win64/espeak-ng.lib`,
  `Android/arm64-v8a/libespeak-ng.so`, `Android/x86_64/libespeak-ng.so`,
  `IOS/arm64/libespeak-ng.a`, `Mac/libespeak-ng.a` — plus the compiled `espeak-ng-data`
  dictionary and phoneme tables, which are themselves derived from GPL-3.0 sources.

A combined work that links GPL-3.0 code must be distributed under GPL-3.0. That applies here,
and it propagates to anything that links this plugin.

### What this means for your game

**Read this before you ship.** These are the questions that actually matter; none of this is
legal advice, and if the answer is load-bearing for your business, get a lawyer.

- **Shipping a closed-source commercial game with this plugin is the problem case.** On iOS and
  macOS eSpeak NG is statically linked into your executable, which is the strongest case for
  GPL-3.0 covering your whole binary. The usual "it's only dynamically linked" argument is not
  available to you on those platforms, and it is contested even where it is.
- **Console and locked-platform stores make it worse, not better.** GPL-3.0's anti-tivoization
  terms (§6) sit badly with platforms that forbid users replacing the binary, and store terms
  frequently conflict with GPL redistribution requirements outright.
- **You must pass on the license and offer source.** GPL-3.0 §6 requires that recipients of the
  binary can obtain the corresponding source for it.
- **If none of that works for you, do not use this plugin.** Use a permissively licensed
  phonemizer, call a phonemization service, or ship pre-phonemized text generated offline so no
  eSpeak NG code is in your shipped build.

### Corresponding source (GPL-3.0 §6)

The complete corresponding source for the binaries in `Source/ThirdParty/` is the eSpeak NG
submodule at `EspeakNG/vendor`, pinned to the exact upstream commit the binaries were built
from:

```
Upstream:  https://github.com/espeak-ng/espeak-ng
Commit:    4870adfa25b1a32b4361592f1be8a40337c58d6c
Version:   1.52.0-dev  (git describe: 1.50-1680-g4870adfa)
```

The build configuration is not hidden either — `EspeakNG/scripts/setup-*.{ps1,sh}` are the exact
scripts that produced the committed binaries, including every CMake flag. Clone with
`--recurse-submodules` and run the matching script to reproduce them.

The vendored sources are unmodified upstream. The plugin's own code is confined to
`Source/InoSpeakNG/`.

### Components under other licenses

eSpeak NG itself bundles a few components under more permissive terms — see `COPYING.APACHE`,
`COPYING.BSD2` and `COPYING.UCD` in the submodule. `libucd` and `libspeechPlayer` are merged
into the iOS/Mac static archives; `COPYING.UCD` covers the former. These do not loosen the
GPL-3.0 terms of the combined work.

eSpeak NG is built here with `USE_LIBPCAUDIO=OFF`, so no audio backend and none of its
dependencies are compiled in.
