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
	 * espeak_Initialize wants. Tries (in order):
	 *   1. Plugin/Binaries/<Platform>/                 (cooked layout)
	 *   2. Plugin/Source/ThirdParty/<Platform>/        (editor / dev layout)
	 *   3. Android: extract from APK assets to writable storage  [TODO]
	 * Returns empty string if no usable location was found.
	 */
	static FString ResolveDataParentPath();
};
