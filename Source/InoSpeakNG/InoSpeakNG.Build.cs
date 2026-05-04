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
		// Layout (matches Option A — self-contained per platform):
		//   Source/ThirdParty/Public/espeak-ng/{encoding,espeak_ng,speak_lib}.h
		//   Source/ThirdParty/Win64/espeak-ng.{dll,lib}
		//   Source/ThirdParty/Win64/espeak-ng-data/
		//   Source/ThirdParty/Android/arm64-v8a/libespeak-ng.so
		//   Source/ThirdParty/Android/arm64-v8a/espeak-ng-data/
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
			string AndroidArm64Dir = Path.Combine(ThirdPartyDir, "Android", "arm64-v8a");

			// Linking the .so via PublicAdditionalLibraries does double duty
			// on Android: tells the linker about the symbols AND tells UBT
			// to bundle the .so into the APK's lib/arm64-v8a/.
			PublicAdditionalLibraries.Add(
				Path.Combine(AndroidArm64Dir, "libespeak-ng.so"));

			// Stage the runtime data tree into the APK. At runtime our
			// wrapper extracts these from the APK to a writable filesystem
			// path so espeak_Initialize can read them as regular files.
			RuntimeDependencies.Add(
				Path.Combine(AndroidArm64Dir, "espeak-ng-data", "..."));
		}
	}
}
