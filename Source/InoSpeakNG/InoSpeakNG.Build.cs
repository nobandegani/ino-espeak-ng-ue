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
		// by EspeakNG/scripts/setup-windows.ps1 and setup-android.ps1.
		//
		// Layout:
		//   Source/ThirdParty/Public/espeak-ng/{encoding,espeak_ng,speak_lib}.h
		//   Source/ThirdParty/Win64/espeak-ng.{dll,lib}
		//   Source/ThirdParty/Win64/espeak-ng-data/
		//   Source/ThirdParty/Android/arm64-v8a/libespeak-ng.so
		//   Source/ThirdParty/Android/x86_64/libespeak-ng.so
		//   Source/ThirdParty/Android/espeak-ng-data/   (shared across arches)
		//
		// Companion file in this same module directory:
		//   InoSpeakNG_UPL_Android.xml   APK packaging directives
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
	}
}
