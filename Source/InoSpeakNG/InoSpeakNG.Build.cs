// Copyright 2026 Inoland. Licensed under GPLv3 (matches espeak-ng).

using System.IO;
using UnrealBuildTool;

public class InoSpeakNG : ModuleRules
{
	public InoSpeakNG(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = ModuleRules.PCHUsageMode.UseExplicitOrSharedPCHs;

		PublicDependencyModuleNames.AddRange(new string[]
		{
			"Core",
		});

		PrivateDependencyModuleNames.AddRange(new string[]
		{
			"CoreUObject",
			"Engine",
			"Projects",   // IPluginManager — used at runtime to resolve the
			              // espeak-ng-data path next to the plugin's binaries.
		});

		// -----------------------------------------------------------------
		// espeak-ng third-party integration
		// -----------------------------------------------------------------
		// Headers and prebuilt libraries live under Source/ThirdParty/, staged
		// by EspeakNG/scripts/setup-windows.ps1, setup-android.ps1,
		// setup-ios.sh, and setup-macos.sh.
		//
		// Layout:
		//   Source/ThirdParty/Public/espeak-ng/{encoding,espeak_ng,speak_lib}.h
		//   Source/ThirdParty/Win64/espeak-ng.{dll,lib}
		//   Source/ThirdParty/Win64/espeak-ng-data/
		//   Source/ThirdParty/Android/arm64-v8a/libespeak-ng.so
		//   Source/ThirdParty/Android/x86_64/libespeak-ng.so
		//   Source/ThirdParty/Android/espeak-ng-data/   (shared across arches)
		//   Source/ThirdParty/IOS/arm64/libespeak-ng.a            (device)
		//   Source/ThirdParty/IOS/arm64-simulator/libespeak-ng.a  (optional)
		//   Source/ThirdParty/IOS/espeak-ng-data/        (shared across slices)
		//   Source/ThirdParty/Mac/libespeak-ng.a         (universal arm64+x86_64)
		//   Source/ThirdParty/Mac/espeak-ng-data/
		//
		// Companion file in this same module directory:
		//   InoSpeakNG_UPL_Android.xml   APK packaging directives
		//
		// iOS / Mac use static linking (.a) rather than a dylib/framework —
		// iOS forbids dlopen of arbitrary dylibs, espeak-ng exposes a small
		// C API directly (no plugin glob-scan), and a static archive avoids
		// dylib loading concerns + embedded-framework code-signing on iOS.
		// Symbols compiled with -fvisibility=hidden still resolve at link
		// time inside the same final binary, so the consumer sees espeak_*
		// normally. Mac stays static (vs. a dylib like Win64) for parity
		// with iOS — same staging shape, same runtime expectations.
		// -----------------------------------------------------------------
		string ThirdPartyDir = Path.Combine(PluginDirectory, "Source", "ThirdParty");

		// Public headers — same on every platform. Using SystemIncludePaths
		// rather than IncludePaths so consumer modules can `#include
		// <espeak-ng/speak_lib.h>` (matches upstream's canonical include
		// style) and warnings from the third-party headers don't poison
		// our build.
		PublicSystemIncludePaths.Add(Path.Combine(ThirdPartyDir, "Public"));

		if (Target.Platform == UnrealTargetPlatform.Win64)
		{
			string Win64Dir = Path.Combine(ThirdPartyDir, "Win64");

			// Link against the import library at compile time.
			PublicAdditionalLibraries.Add(Path.Combine(Win64Dir, "espeak-ng.lib"));

			// Stage the runtime DLL next to the plugin module's DLL so the
			// loader finds it on PATH.
			RuntimeDependencies.Add(
				"$(BinaryOutputDir)/espeak-ng.dll",
				Path.Combine(Win64Dir, "espeak-ng.dll"),
				StagedFileType.NonUFS);

			// Stage the runtime data tree (~3 MB of phoneme/dict tables).
			// The "/..." suffix copies the directory recursively.
			RuntimeDependencies.Add(
				"$(BinaryOutputDir)/espeak-ng-data/...",
				Path.Combine(Win64Dir, "espeak-ng-data", "..."),
				StagedFileType.NonUFS);
		}
		else if (Target.Platform == UnrealTargetPlatform.Android)
		{
			// Android multi-arch (arm64-v8a + x86_64). Iterate both arches
			// and File.Exists-guard each .so so a partial build (e.g. only
			// arm64) still configures cleanly. UBT runs Build.cs once per
			// target architecture, so only the matching arch's .so will
			// actually be linked into the per-arch build output. Files for
			// non-target arches in PublicAdditionalLibraries are silently
			// ignored by UBT.
			//
			// Same staging shape as the sibling InoLiteRT plugin (see
			// Plugins/InoLiteRT/Source/InoLiteRT/InoLiteRT.Build.cs:144-188).

			string AndroidBaseDir = Path.Combine(ThirdPartyDir, "Android");

			string[] AndroidArches = new string[] { "arm64-v8a", "x86_64" };

			foreach (string Arch in AndroidArches)
			{
				string ArchDir = Path.Combine(AndroidBaseDir, Arch);
				string SoPath  = Path.Combine(ArchDir, "libespeak-ng.so");

				if (File.Exists(SoPath))
				{
					// Linking the .so via PublicAdditionalLibraries gives
					// libUnreal.so a DT_NEEDED on libespeak-ng.so so the
					// dynamic linker auto-resolves the symbols at process
					// start. UBT also keeps the .so on the build receipt.
					// The actual APK inclusion (lib/<arch>/libespeak-ng.so)
					// happens via the UPL XML's <copyFile> below.
					PublicAdditionalLibraries.Add(SoPath);
					RuntimeDependencies.Add(SoPath);
				}
			}

			// Stage the espeak-ng-data tree as UFS so it goes into the
			// game's pak file. UE's IFileManager reads it transparently
			// from the pak; on first run our StartupModule extracts the
			// tree to FPaths::ProjectPersistentDownloadDir() so espeak-ng's
			// raw fopen() can open the files (espeak-ng has no AAssetManager
			// integration upstream — fopen is its only IO path).
			//
			// Single shared copy (not per-arch) because the data files are
			// arch-agnostic — same dictionaries / phoneme tables work for
			// every Android arch. See setup-android.ps1's $AndroidDataDir.
			string DataDir = Path.Combine(AndroidBaseDir, "espeak-ng-data");
			if (Directory.Exists(DataDir))
			{
				RuntimeDependencies.Add(
					Path.Combine(AndroidBaseDir, "espeak-ng-data", "..."),
					StagedFileType.UFS);
			}

			// Apply the UPL (Unreal Plugin Language) XML that tells UE's
			// APK packager to copy libespeak-ng.so into lib/<arch>/ and
			// emit a System.loadLibrary("espeak-ng") call so the .so is
			// resident before libUnreal.so finishes initializing.
			AdditionalPropertiesForReceipt.Add(
				"AndroidPlugin",
				Path.Combine(ModuleDirectory, "InoSpeakNG_UPL_Android.xml"));
		}
		else if (Target.Platform == UnrealTargetPlatform.IOS)
		{
			// iOS: link the static library produced by EspeakNG/scripts/
			// setup-ios.sh. Build.cs only consumes the arm64 device slice;
			// the script can also produce arm64-simulator under
			// Source/ThirdParty/IOS/arm64-simulator/ but that slice has to
			// be wired in manually (UE 5.7's Simulator target needs an
			// extra DependenciesToSkipPerArchitecture entry to keep the
			// device .a out of the simulator link, and we don't ship a
			// Simulator target by default).
			//
			// File.Exists guard keeps the configure step succeeding when
			// the developer hasn't run setup-ios.sh yet (cross-platform
			// devs on Windows have to do all iOS work on a Mac). In that
			// case the build still produces a valid InoSpeakNG module —
			// it just has no espeak symbols to call, and IsAvailable()
			// returns false at runtime.

			string IOSBaseDir = Path.Combine(ThirdPartyDir, "IOS");
			string Arm64Dir   = Path.Combine(IOSBaseDir, "arm64");
			string LibPath    = Path.Combine(Arm64Dir, "libespeak-ng.a");

			if (File.Exists(LibPath))
			{
				// PublicAdditionalLibraries pulls the .a's object code
				// into the final iOS executable at link time. No DT_NEEDED
				// entry is created (it's not a dylib), so there's nothing
				// for the dynamic linker to resolve at launch — symbols
				// are baked in. Do NOT add the .a to RuntimeDependencies:
				// that stages it into the .app bundle, and App Store
				// validation rejects bundles containing standalone
				// libraries ("Invalid bundle structure").
				PublicAdditionalLibraries.Add(LibPath);
			}

			// Stage the espeak-ng-data tree as UFS so it goes into the
			// game's pak file. iOS apps run in a sandbox where the .app
			// bundle is read-only and pak files live under a path that
			// espeak-ng's raw fopen() can't read. On first run our
			// StartupModule extracts the tree to FPaths::ProjectPersistent-
			// DownloadDir() (a writable path under the app's Documents
			// folder, marked NSURLIsExcludedFromBackupKey) so espeak_Init
			// can fopen() the dictionaries normally.
			//
			// Single shared copy (not per-slice) because the data files
			// are platform-agnostic — same dictionaries / phoneme tables
			// work for every iOS slice. See setup-ios.sh's $IOS_DATA_DIR.
			string IOSDataDir = Path.Combine(IOSBaseDir, "espeak-ng-data");
			if (Directory.Exists(IOSDataDir))
			{
				RuntimeDependencies.Add(
					Path.Combine(IOSBaseDir, "espeak-ng-data", "..."),
					StagedFileType.UFS);
			}

			// No IPL XML needed: espeak-ng requires no Info.plist additions
			// (no audio session category, no entitlements, no usage
			// descriptions — phonemization is pure CPU work with no system
			// service calls).
		}
		else if (Target.Platform == UnrealTargetPlatform.Mac)
		{
			// Mac: link the universal static library produced by
			// EspeakNG/scripts/setup-macos.sh (default --abi=universal
			// produces an arm64+x86_64 fat archive that satisfies both
			// Apple Silicon and Intel UE targets in one file). Single-arch
			// builds also work — `lipo`-stripping the .a doesn't matter
			// here because Mac targets pick the matching slice at link
			// time without any per-arch filtering.
			//
			// File.Exists guard keeps configure succeeding when the user
			// hasn't run setup-macos.sh yet (a clean checkout configures
			// cleanly; IsAvailable() returns false at runtime if the .a
			// is missing).

			string MacDir  = Path.Combine(ThirdPartyDir, "Mac");
			string LibPath = Path.Combine(MacDir, "libespeak-ng.a");

			if (File.Exists(LibPath))
			{
				// Link-time only — staging the .a would trip the same
				// App Store / notarization bundle-structure check as iOS.
				PublicAdditionalLibraries.Add(LibPath);
			}

			// Stage the runtime data tree as NonUFS so the cooker drops
			// it into the .app bundle as loose files alongside the binary
			// (mirrors the Win64 pattern). Mac is desktop-style — no pak
			// extract step needed at runtime, fopen() reads it directly.
			//
			// The "/..." suffix copies the directory recursively. Path
			// $(BinaryOutputDir) for a Mac plugin module points at the
			// bundled module location; the runtime probe in
			// FInoSpeakNGModule::ResolveDataParentPath finds it via the
			// same Plugin/Binaries/Mac/ candidate the Win64 path uses.
			string DataDir = Path.Combine(MacDir, "espeak-ng-data");
			if (Directory.Exists(DataDir))
			{
				RuntimeDependencies.Add(
					"$(BinaryOutputDir)/espeak-ng-data/...",
					Path.Combine(MacDir, "espeak-ng-data", "..."),
					StagedFileType.NonUFS);
			}
		}
	}
}
