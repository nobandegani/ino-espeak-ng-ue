// Copyright 2026 Inoland. Licensed under GPLv3 (matches espeak-ng).

#include "InoSpeakNG.h"

#include "HAL/FileManager.h"
#include "HAL/PlatformFileManager.h"
#include "Interfaces/IPluginManager.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"

#include <espeak-ng/speak_lib.h>

DEFINE_LOG_CATEGORY(LogInoSpeakNG);

#define LOCTEXT_NAMESPACE "FInoSpeakNGModule"

namespace
{
	/** Set true after a successful espeak_Initialize. Reset on Terminate. */
	bool gIsInitialized = false;

	/** Parent of espeak-ng-data, in the form passed to espeak_Initialize. */
	FString gDataParentPath;

	const TCHAR* PlatformSubdir()
	{
#if PLATFORM_WINDOWS
		return TEXT("Win64");
#elif PLATFORM_MAC
		return TEXT("Mac");
#elif PLATFORM_ANDROID || PLATFORM_IOS
		// Android / iOS resolve data via ExtractEspeakDataIfNeeded() rather
		// than a static plugin-relative path; PlatformSubdir is unused on
		// those platforms (the extractor names the source dir directly).
		return nullptr;
#else
		return nullptr;
#endif
	}

#if PLATFORM_ANDROID || PLATFORM_IOS
	// Bumped when we change the bundled espeak-ng-data (e.g. vendor pin
	// update). On app upgrade the stamp mismatch triggers re-extraction
	// so old/new versions can't get crossed. Format is freeform — any
	// string change forces re-extraction.
	const TCHAR* kEspeakDataStamp = TEXT("v1.52.0-1");

	/**
	 * Source-tree subdir under Source/ThirdParty/ that holds the staged
	 * espeak-ng-data/ for the current platform. Build.cs stages each
	 * platform's data under its own subdir (Android/, IOS/) — the data
	 * itself is platform-agnostic, but the staging tree is per-platform
	 * so cooks for one platform don't pull in the other's files.
	 */
	const TCHAR* MobilePlatformSubdir()
	{
#if PLATFORM_ANDROID
		return TEXT("Android");
#elif PLATFORM_IOS
		return TEXT("IOS");
#else
		return TEXT("");
#endif
	}

	/**
	 * Recursively copy a directory tree using UE's IFileManager. This is
	 * how we get espeak-ng-data out of the read-only pak/asset filesystem
	 * and onto a real on-device filesystem path that espeak-ng's raw
	 * fopen() can read. Returns false on any I/O error.
	 */
	bool CopyTreeViaFileManager(const FString& SrcDir, const FString& DstDir)
	{
		IFileManager& FM = IFileManager::Get();

		TArray<FString> SrcFiles;
		FM.FindFilesRecursive(SrcFiles, *SrcDir, TEXT("*"),
			/*Files=*/true, /*Directories=*/false);
		if (SrcFiles.Num() == 0)
		{
			UE_LOG(LogInoSpeakNG, Error,
				TEXT("CopyTreeViaFileManager: no files under %s — data not staged?"),
				*SrcDir);
			return false;
		}

		const FString SrcDirNorm = SrcDir / TEXT("");
		for (const FString& Src : SrcFiles)
		{
			FString Rel = Src;
			FPaths::MakePathRelativeTo(Rel, *SrcDirNorm);

			const FString Dst = FPaths::Combine(DstDir, Rel);
			FM.MakeDirectory(*FPaths::GetPath(Dst), /*Tree=*/true);

			if (FM.Copy(*Dst, *Src) != COPY_OK)
			{
				UE_LOG(LogInoSpeakNG, Error,
					TEXT("CopyTreeViaFileManager: failed to copy %s -> %s"),
					*Src, *Dst);
				return false;
			}
		}
		UE_LOG(LogInoSpeakNG, Log,
			TEXT("CopyTreeViaFileManager: %d files copied %s -> %s"),
			SrcFiles.Num(), *SrcDir, *DstDir);
		return true;
	}

	/**
	 * Extract espeak-ng-data from the pak/asset filesystem onto a writable
	 * on-device path so espeak-ng's raw fopen() can open the dictionaries.
	 * Idempotent: a stamp file under PersistentDownloadDir/ino-speak-ng/
	 * is checked first, and the extraction is skipped if it matches.
	 *
	 * Returns the parent directory containing espeak-ng-data/ (the form
	 * espeak_Initialize wants), or empty string on failure.
	 *
	 * The source tree is staged by Build.cs's RuntimeDependencies entry
	 * (UFS) at Plugins/InoSpeakNG/Source/ThirdParty/<Platform>/espeak-ng-data/
	 * relative to the plugin's base dir, where <Platform> is "Android" or
	 * "IOS" (selected by MobilePlatformSubdir).
	 *
	 * Why extract on iOS too? The same constraint as Android applies: the
	 * .ipa's pak file lives at a path espeak-ng's raw fopen() can't read,
	 * and the iOS app sandbox makes Documents/ the closest writable location
	 * (FPaths::ProjectPersistentDownloadDir resolves there and excludes the
	 * tree from iCloud backup automatically — see FIOSPlatformMisc::
	 * GamePersistentDownloadDir).
	 */
	FString ExtractEspeakDataIfNeeded()
	{
		IFileManager& FM = IFileManager::Get();

		const FString DstParent = FPaths::Combine(
			FPaths::ProjectPersistentDownloadDir(),
			TEXT("ino-speak-ng"));
		const FString DstData  = FPaths::Combine(DstParent, TEXT("espeak-ng-data"));
		const FString StampFile = FPaths::Combine(DstParent, TEXT(".espeak-data-stamp"));

		// Already extracted at the right version? Stamp file + dir presence
		// gate further work. The stamp is only written after a successful
		// copy, so a partial extraction is auto-recovered next launch.
		FString CurrentStamp;
		if (FFileHelper::LoadFileToString(CurrentStamp, *StampFile)
			&& CurrentStamp.TrimStartAndEnd() == kEspeakDataStamp
			&& FM.DirectoryExists(*DstData))
		{
			UE_LOG(LogInoSpeakNG, Log,
				TEXT("espeak-ng-data already extracted at %s (stamp %s)"),
				*DstData, *CurrentStamp.TrimStartAndEnd());
			return DstParent;
		}

		// Locate the source. Build.cs stages the tree at
		// <plugin>/Source/ThirdParty/<Platform>/espeak-ng-data/ (no arch
		// subdir — the data is platform-agnostic). UE's IFileManager wraps
		// the pak / asset filesystem so this path resolves transparently
		// regardless of how the platform installer packed the files.
		TSharedPtr<IPlugin> Plugin = IPluginManager::Get().FindPlugin(TEXT("InoSpeakNG"));
		if (!Plugin.IsValid())
		{
			UE_LOG(LogInoSpeakNG, Error,
				TEXT("ExtractEspeakDataIfNeeded: InoSpeakNG plugin not registered."));
			return FString();
		}
		const FString SrcData = FPaths::Combine(
			Plugin->GetBaseDir(),
			TEXT("Source"), TEXT("ThirdParty"),
			MobilePlatformSubdir(),
			TEXT("espeak-ng-data"));

		UE_LOG(LogInoSpeakNG, Log,
			TEXT("Extracting espeak-ng-data: %s -> %s"), *SrcData, *DstData);

		// Wipe any stale partial extraction before retrying so a previous
		// failure can't leave a half-populated tree.
		FM.DeleteDirectory(*DstData, /*RequireExists=*/false, /*Tree=*/true);
		FM.MakeDirectory(*DstParent, /*Tree=*/true);

		if (!CopyTreeViaFileManager(SrcData, DstData))
		{
			return FString();
		}

		// Write the stamp last so we only mark the extraction done if the
		// copy succeeded end-to-end.
		if (!FFileHelper::SaveStringToFile(FString(kEspeakDataStamp), *StampFile))
		{
			UE_LOG(LogInoSpeakNG, Warning,
				TEXT("ExtractEspeakDataIfNeeded: failed to write stamp file %s; ")
				TEXT("data is extracted but may be re-copied on next launch."),
				*StampFile);
		}
		UE_LOG(LogInoSpeakNG, Log,
			TEXT("espeak-ng-data extraction complete; parent=%s"), *DstParent);
		return DstParent;
	}
#endif  // PLATFORM_ANDROID || PLATFORM_IOS
}

void FInoSpeakNGModule::StartupModule()
{
	const FString ParentPath = ResolveDataParentPath();
	if (ParentPath.IsEmpty())
	{
		UE_LOG(LogInoSpeakNG, Error,
			TEXT("Could not locate espeak-ng-data; phonemizer disabled. ")
			TEXT("Run EspeakNG/scripts/setup-windows.ps1 (and setup-android.ps1, ")
			TEXT("setup-ios.sh, setup-macos.sh) under Plugins/InoSpeakNG/."));
		return;
	}

	UE_LOG(LogInoSpeakNG, Log, TEXT("espeak-ng data root: %s"), *ParentPath);

	// espeak_Initialize wants ANSI; convert from TCHAR.
	const FTCHARToUTF8 PathUtf8(*ParentPath);

	// AUDIO_OUTPUT_RETRIEVAL means "no audio device, no synchronous playback" —
	// we only ever call espeak_TextToPhonemes, never espeak_Synth, so nothing
	// audio-related actually runs. We deliberately built libespeak-ng with
	// USE_LIBPCAUDIO=OFF, so the playback modes wouldn't work anyway.
	const int SampleRate = espeak_Initialize(
		AUDIO_OUTPUT_RETRIEVAL,
		/*buflength*/ 0,
		PathUtf8.Get(),
		/*options*/ 0);

	if (SampleRate < 0)
	{
		UE_LOG(LogInoSpeakNG, Error,
			TEXT("espeak_Initialize failed (returned %d)."), SampleRate);
		return;
	}

	gIsInitialized = true;
	gDataParentPath = ParentPath;
	UE_LOG(LogInoSpeakNG, Log,
		TEXT("espeak-ng initialized; internal sample rate %d Hz."), SampleRate);
}

void FInoSpeakNGModule::ShutdownModule()
{
	if (gIsInitialized)
	{
		espeak_Terminate();
		gIsInitialized = false;
		gDataParentPath.Empty();
		UE_LOG(LogInoSpeakNG, Log, TEXT("espeak-ng terminated."));
	}
}

bool FInoSpeakNGModule::IsAvailable()
{
	return gIsInitialized;
}

FString FInoSpeakNGModule::GetDataParentPath()
{
	return gDataParentPath;
}

FString FInoSpeakNGModule::ResolveDataParentPath()
{
#if PLATFORM_ANDROID || PLATFORM_IOS
	// On Android / iOS the data lives inside the pak / APK / IPA assets,
	// which espeak-ng's raw fopen() can't read. Extract once on first run
	// to FPaths::ProjectPersistentDownloadDir() (a real filesystem path —
	// /data/data/<pkg>/files/ on Android, the app sandbox's Documents/
	// on iOS) and use that going forward.
	return ExtractEspeakDataIfNeeded();
#else
	const TCHAR* Platform = PlatformSubdir();
	if (!Platform)
	{
		UE_LOG(LogInoSpeakNG, Error,
			TEXT("ResolveDataParentPath: PlatformSubdir() is null on this platform — ")
			TEXT("InoSpeakNG only supports Win64, Mac, Android, and iOS."));
		return FString();
	}

	TSharedPtr<IPlugin> Plugin = IPluginManager::Get().FindPlugin(TEXT("InoSpeakNG"));
	if (!Plugin.IsValid())
	{
		UE_LOG(LogInoSpeakNG, Error,
			TEXT("ResolveDataParentPath: IPluginManager couldn't find 'InoSpeakNG' — ")
			TEXT("plugin not registered with the engine?"));
		return FString();
	}

	const FString PluginBase = Plugin->GetBaseDir();
	IFileManager& FM = IFileManager::Get();

	UE_LOG(LogInoSpeakNG, Log,
		TEXT("ResolveDataParentPath: plugin base dir = %s"), *PluginBase);

	// Try every known layout. Log each candidate explicitly so a packaged-
	// build user can see which paths we probed (and therefore which the
	// cook should have staged into).
	auto TryDir = [&FM](const FString& ParentDir, const TCHAR* Label) -> FString
	{
		const FString DataDir = FPaths::Combine(ParentDir, TEXT("espeak-ng-data"));
		const bool    bExists = FM.DirectoryExists(*DataDir);
		UE_LOG(LogInoSpeakNG, Log,
			TEXT("ResolveDataParentPath: %s candidate '%s' -> %s"),
			Label, *DataDir, bExists ? TEXT("FOUND") : TEXT("missing"));
		return bExists ? ParentDir : FString();
	};

	// 1. Cooked layout: <plugin>/Binaries/<Platform>/espeak-ng-data/
	if (FString Found = TryDir(
			FPaths::Combine(PluginBase, TEXT("Binaries"), Platform),
			TEXT("[cooked]"));
		!Found.IsEmpty())
	{
		return Found;
	}

	// 2. Dev/editor layout: <plugin>/Source/ThirdParty/<Platform>/espeak-ng-data/
	if (FString Found = TryDir(
			FPaths::Combine(PluginBase, TEXT("Source"), TEXT("ThirdParty"), Platform),
			TEXT("[dev/editor]"));
		!Found.IsEmpty())
	{
		return Found;
	}

	// 3. Cooked alternative: <project>/Binaries/<Platform>/espeak-ng-data/
	//    Some UE staging configurations flatten plugin Binaries into the
	//    project's Binaries dir instead of keeping them under each plugin.
	if (FString Found = TryDir(
			FPaths::Combine(FPaths::ProjectDir(), TEXT("Binaries"), Platform),
			TEXT("[project-binaries]"));
		!Found.IsEmpty())
	{
		return Found;
	}

	// 4. Last-ditch: alongside the executable.
	if (FString Found = TryDir(
			FPaths::GetPath(FPlatformProcess::ExecutablePath()),
			TEXT("[exec-dir]"));
		!Found.IsEmpty())
	{
		return Found;
	}

	UE_LOG(LogInoSpeakNG, Error,
		TEXT("ResolveDataParentPath: no candidate layout contained espeak-ng-data. ")
		TEXT("Cook didn't stage the data tree. Verify Plugins/InoSpeakNG/Source/")
		TEXT("InoSpeakNG/InoSpeakNG.Build.cs adds the espeak-ng-data RuntimeDependency, ")
		TEXT("and that the staged Source/ThirdParty/%s/ dir actually contains the files (run ")
		TEXT("the matching Plugins/InoSpeakNG/EspeakNG/scripts/setup-*.{ps1,sh} script if not)."),
		Platform);
	return FString();
#endif
}

#undef LOCTEXT_NAMESPACE

IMPLEMENT_MODULE(FInoSpeakNGModule, InoSpeakNG)
