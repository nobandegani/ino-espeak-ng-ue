// Copyright 2026 Inoland. Licensed under GPLv3 (matches espeak-ng).

#include "InoSpeakNG.h"

#include "Interfaces/IPluginManager.h"
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
#elif PLATFORM_ANDROID
		return TEXT("Android/arm64-v8a");
#else
		return nullptr;
#endif
	}
}

void FInoSpeakNGModule::StartupModule()
{
	const FString ParentPath = ResolveDataParentPath();
	if (ParentPath.IsEmpty())
	{
		UE_LOG(LogInoSpeakNG, Error,
			TEXT("Could not locate espeak-ng-data; phonemizer disabled. ")
			TEXT("Run EspeakNG/scripts/setup-windows.ps1 (and setup-android.ps1) ")
			TEXT("under Plugins/InoSpeakNG/."));
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
	const TCHAR* Platform = PlatformSubdir();
	if (!Platform)
	{
		return FString();
	}

	TSharedPtr<IPlugin> Plugin = IPluginManager::Get().FindPlugin(TEXT("InoSpeakNG"));
	if (!Plugin.IsValid())
	{
		return FString();
	}

	const FString PluginBase = Plugin->GetBaseDir();
	IFileManager& FM = IFileManager::Get();

	// 1. Cooked layout: <plugin>/Binaries/<Platform>/espeak-ng-data/
	{
		const FString ParentDir   = FPaths::Combine(PluginBase, TEXT("Binaries"), Platform);
		const FString DataDir     = FPaths::Combine(ParentDir, TEXT("espeak-ng-data"));
		if (FM.DirectoryExists(*DataDir))
		{
			return ParentDir;
		}
	}

	// 2. Dev/editor layout: <plugin>/Source/ThirdParty/<Platform>/espeak-ng-data/
	{
		const FString ParentDir = FPaths::Combine(
			PluginBase, TEXT("Source"), TEXT("ThirdParty"), Platform);
		const FString DataDir = FPaths::Combine(ParentDir, TEXT("espeak-ng-data"));
		if (FM.DirectoryExists(*DataDir))
		{
			return ParentDir;
		}
	}

#if PLATFORM_ANDROID
	// 3. Android cooked: data is inside the APK as compressed assets.
	// espeak uses raw fopen(), so we need to extract files to a writable
	// filesystem location before initialization. Not yet implemented.
	UE_LOG(LogInoSpeakNG, Warning,
		TEXT("Android APK data extraction not yet implemented. ")
		TEXT("espeak-ng will be unavailable on this platform until extracted."));
#endif

	return FString();
}

#undef LOCTEXT_NAMESPACE

IMPLEMENT_MODULE(FInoSpeakNGModule, InoSpeakNG)
