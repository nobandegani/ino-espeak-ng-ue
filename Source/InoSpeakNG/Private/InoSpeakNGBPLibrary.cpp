// Copyright 2026 Inoland. Licensed under GPLv3 (matches espeak-ng).

#include "InoSpeakNGBPLibrary.h"
#include "InoSpeakNG.h"

#include <espeak-ng/speak_lib.h>

FString UInoSpeakNGBPLibrary::Phonemize(const FString& Text, const FString& LanguageCode)
{
	if (!FInoSpeakNGModule::IsAvailable())
	{
		UE_LOG(LogInoSpeakNG, Warning,
			TEXT("Phonemize called but espeak-ng is not initialized."));
		return FString();
	}

	if (Text.IsEmpty())
	{
		return FString();
	}

	// Select voice by language code (e.g. "en-us"). espeak's voice files
	// live under espeak-ng-data/voices/!v/ and the language is identified
	// by the eSpeak language code.
	const FTCHARToUTF8 LangUtf8(*LanguageCode);
	if (espeak_SetVoiceByName(LangUtf8.Get()) != EE_OK)
	{
		UE_LOG(LogInoSpeakNG, Warning,
			TEXT("espeak_SetVoiceByName failed for language '%s'."), *LanguageCode);
		return FString();
	}

	// espeak_TextToPhonemes processes one *clause* per call (sentence /
	// comma / semicolon / etc), advancing the input pointer. It returns
	// NULL through *textptr when the buffer is exhausted. Returned strings
	// live in espeak's static buffer and are overwritten on the next call,
	// so copy out as we go.
	const FTCHARToUTF8 TextUtf8(*Text);
	const void* TextPtr = TextUtf8.Get();

	// phonememode bits (per speak_lib.h:504-512):
	//   bits 0-2:
	//     0 = no output
	//     1 = eSpeak ASCII phoneme names (e.g. h@l'oU)
	//     2 = IPA phoneme names as UTF-8 (e.g. həlˈoʊ)   <-- what we want
	//   bit 3   = trace
	//   bit 4   = mbrola
	//   bit 7   = use bits 8-23 as a tie char within multi-letter phonemes
	//   bits 8-23 = separator character between phonemes (0 = no separator)
	const int PhonemeMode = 2;

	FString Result;
	while (TextPtr != nullptr)
	{
		const char* Phonemes = espeak_TextToPhonemes(
			&TextPtr,
			espeakCHARS_UTF8,
			PhonemeMode);

		if (Phonemes && *Phonemes)
		{
			if (!Result.IsEmpty())
			{
				Result += TEXT(" ");
			}
			Result += UTF8_TO_TCHAR(Phonemes);
		}
	}

	return Result;
}

bool UInoSpeakNGBPLibrary::IsAvailable()
{
	return FInoSpeakNGModule::IsAvailable();
}
