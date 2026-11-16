import Foundation

struct TranslationResult {
    let sourceText: String
    let translatedText: String
    let sourceIsRussian: Bool
    let matched: Bool
    let tipRu: String
    let tag: LibraryTag
    let fallbackSpokenRU: String?
    var viaGemini: Bool = false
    /// Short RU reason when Gemini was expected but failed (shown in UI).
    var geminiErrorRU: String? = nil
    /// Photo pipeline (§2): what is on the snapshot.
    var photo: PhotoIdentifyResult? = nil
}

/// Structured site-photo ID: object first, then OCR/translate.
struct PhotoIdentifyResult: Equatable {
    var nameEN: String
    var nameRU: String
    /// tool | part | label | document | sign | other
    var kind: String
    var confidence: String
    var ocrText: String
    var translationRU: String
    var translationEN: String
    var documentGuess: String
    var summaryRU: String
    var keyFields: [String]
    var siteTipEN: String
    var siteTipRU: String
    var unclear: Bool

    var listenEN: String {
        let tip = siteTipEN.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tip.isEmpty { return tip }
        let name = nameEN.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return translationEN
    }
}

enum TranslationService {
    static func translateOffline(recognized: String) -> TranslationResult {
        let text = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = LanguageDetect.classify(text)
        let sourceIsRU = kind == .russian

        if let hit = PhraseBank.searchBank(normalized: text) {
            if sourceIsRU {
                return TranslationResult(
                    sourceText: text,
                    translatedText: hit.en,
                    sourceIsRussian: true,
                    matched: true,
                    tipRu: hit.tipRu,
                    tag: hit.libraryTag,
                    fallbackSpokenRU: nil,
                    viaGemini: false
                )
            }
            return TranslationResult(
                sourceText: text,
                translatedText: hit.ru,
                sourceIsRussian: false,
                matched: true,
                tipRu: hit.tipRu,
                tag: hit.libraryTag,
                fallbackSpokenRU: nil,
                viaGemini: false
            )
        }

        let draft = "Нет точного перевода офлайн. Сохранил в библиотеку как черновик — разберём позже."
        if sourceIsRU {
            return TranslationResult(
                sourceText: text,
                translatedText: "(перевод позже)",
                sourceIsRussian: true,
                matched: false,
                tipRu: "",
                tag: .other,
                fallbackSpokenRU: draft,
                viaGemini: false
            )
        }
        return TranslationResult(
            sourceText: text,
            translatedText: "(разбор позже)",
            sourceIsRussian: false,
            matched: false,
            tipRu: "",
            tag: .other,
            fallbackSpokenRU: draft,
            viaGemini: false
        )
    }

    /// PhraseBank → ML Kit offline (if preferred/ready) → Gemini online.
    static func translate(
        recognized: String,
        settings: AppSettings,
        sourceLanguage: TranslatorSourceLanguage
    ) async -> TranslationResult {
        let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return TranslationResult(
                sourceText: recognized,
                translatedText: "",
                sourceIsRussian: false,
                matched: false,
                tipRu: "",
                tag: .other,
                fallbackSpokenRU: nil,
                viaGemini: false,
                geminiErrorRU: "Не расслышал — скажи ещё раз"
            )
        }

        // Exact site bank (EN↔RU) still wins when it hits.
        let bank = translateOffline(recognized: trimmed)
        if bank.matched { return bank }

        let preferOffline = settings.preferOfflineTranslation
        if preferOffline || !settings.geminiEnabledAndReady {
            do {
                return try await MLKitOfflineTranslateService.shared.translateText(
                    trimmed,
                    source: sourceLanguage
                )
            } catch let e as MLKitOfflineError {
                if !settings.geminiEnabledAndReady {
                    var o = bank
                    o.geminiErrorRU = e.shortRU
                    return o
                }
                // Fall through to Gemini when online is allowed.
            } catch {
                if !settings.geminiEnabledAndReady {
                    var o = bank
                    o.geminiErrorRU = "Офлайн-перевод не вышел"
                    return o
                }
            }
        }

        guard settings.geminiEnabledAndReady else {
            var o = bank
            if settings.useGemini && !settings.hasGeminiKey {
                o.geminiErrorRU = "Нет ключа Gemini в Настройках"
            } else if !settings.useGemini {
                o.geminiErrorRU = "Включи Gemini или скачай офлайн-модель"
            }
            return o
        }

        do {
            return try await GeminiSiteCoachService.shared.translateThrowing(
                text: trimmed,
                sourceHint: .auto,
                sourceLanguageCode: sourceLanguage.geminiSourceHint
            )
        } catch let e as GeminiRequestError {
            // Online failed — last try ML Kit if we skipped it earlier.
            if !preferOffline {
                if let ml = try? await MLKitOfflineTranslateService.shared.translateText(
                    trimmed,
                    source: sourceLanguage
                ) {
                    return ml
                }
            }
            var o = bank
            o.geminiErrorRU = e.shortRU
            return o
        } catch {
            var o = bank
            o.geminiErrorRU = "Нет сети / таймаут Gemini"
            return o
        }
    }

    /// Public for Translator STT locale + auto RU↔EN direction.
    static func isMostlyRussian(_ text: String) -> Bool {
        LanguageDetect.isMostlyRussian(text)
    }

    /// Mic locale follows the language picker — never flips to ru-RU on empty input.
    static func translatorMicLocaleId(
        sourceLanguage: TranslatorSourceLanguage,
        englishLocale: String
    ) -> String {
        sourceLanguage.speechLocaleId(englishLocale: englishLocale)
    }
}
