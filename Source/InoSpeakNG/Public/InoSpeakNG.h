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
	 * Win64 / desktop layouts try (in order):
	 *   1. Plugin/Binaries/<Platform>/             (cooked / packaged layout)
	 *   2. Plugin/Source/ThirdParty/<Platform>/    (editor / dev layout)
	 *
	 * Android: the staged data is inside the pak/APK assets which espeak-ng's
	 * raw fopen() can't read. On first run the data tree is extracted from
	 * the pak to FPaths::ProjectPersistentDownloadDir()/InoSpeakNG/, which
	 * is a real filesystem path on /data/data/<pkg>/files/. Subsequent
	 * launches reuse the extracted copy via a stamp-file check (re-extracts
	 * automatically when the bundled data version changes).
	 *
	 * Returns empty string if no usable location was found.
	 */
	static FString ResolveDataParentPath();
};
