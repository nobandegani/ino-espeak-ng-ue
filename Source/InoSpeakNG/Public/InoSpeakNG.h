// Copyright 2026 Inoland. Licensed under GPLv3 (matches espeak-ng).

#pragma once

#include "CoreMinimal.h"
#include "Modules/ModuleManager.h"

DECLARE_LOG_CATEGORY_EXTERN(LogInoSpeakNG, Log, All);

class INOSPEAKNG_API FInoSpeakNGModule : public IModuleInterface
{
public:
	virtual void StartupModule() override;
	virtual void ShutdownModule() override;

	/** True iff espeak_Initialize succeeded at module startup. */
	static bool IsAvailable();

	/** Resolved parent of the espeak-ng-data directory used at runtime. */
	static FString GetDataParentPath();

private:
	/**
	 * Locates the directory that *contains* espeak-ng-data, which is what
	 * espeak_Initialize wants.
	 *
	 * Win64 / Mac (desktop) layouts try (in order):
	 *   1. Plugin/Binaries/<Platform>/             (cooked / packaged layout)
	 *   2. Plugin/Source/ThirdParty/<Platform>/    (editor / dev layout)
	 *   3. Project/Binaries/<Platform>/            (cooked alt — flattened)
	 *   4. Alongside the executable                (last-ditch)
	 *
	 * Android / iOS: the staged data is inside the pak / APK / IPA assets
	 * which espeak-ng's raw fopen() can't read. On first run the data tree
	 * is extracted from the pak to FPaths::ProjectPersistentDownloadDir()/
	 * ino-speak-ng/ — a real on-device filesystem path
	 * (/data/data/<pkg>/files/ on Android, the app sandbox's Documents/
	 * directory on iOS, marked NSURLIsExcludedFromBackupKey by UE).
	 * Subsequent launches reuse the extracted copy via a stamp-file check
	 * (re-extracts automatically when the bundled data version changes).
	 *
	 * Returns empty string if no usable location was found.
	 */
	static FString ResolveDataParentPath();
};
