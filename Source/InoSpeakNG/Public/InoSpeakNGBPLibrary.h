// Copyright 2026 Inoland. Licensed under GPLv3 (matches espeak-ng).

#pragma once

#include "CoreMinimal.h"
#include "Kismet/BlueprintFunctionLibrary.h"
#include "InoSpeakNGBPLibrary.generated.h"

UCLASS()
class INOSPEAKNG_API UInoSpeakNGBPLibrary : public UBlueprintFunctionLibrary
{
	GENERATED_BODY()

public:
	/**
	 * Convert text to IPA phonemes via espeak-ng. Returns the IPA string,
	 * or an empty string on failure (engine not initialized, unknown
	 * language code, etc).
	 *
	 * Not thread-safe — espeak-ng uses internal static buffers, so call
	 * this from one thread at a time. The Blueprint VM is single-threaded
	 * so the default game-thread call site is fine.
	 *
	 * @param Text          Plain text in any of the supported source languages.
	 * @param LanguageCode  espeak language code, e.g. "en-us", "de", "fr-fr",
	 *                      "es", "ar", etc. See espeak-ng-data/voices/ for
	 *                      the full list.
	 * @return              IPA phonemes (UTF-8) or empty string on failure.
	 */
	UFUNCTION(BlueprintCallable, Category = "InoSpeakNG",
		meta = (DisplayName = "Phonemize Text (IPA)"))
	static FString Phonemize(const FString& Text, const FString& LanguageCode = TEXT("en-us"));

	/** True iff espeak-ng was successfully initialized at module startup. */
	UFUNCTION(BlueprintPure, Category = "InoSpeakNG")
	static bool IsAvailable();
};
