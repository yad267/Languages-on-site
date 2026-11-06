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

    /// Offline first; if unmatched and Gemini ON+key → MUST call API (errors surface in geminiErrorRU).
    static func translate(recognized: String, settings: AppSettings) async -> TranslationResult {
        let kind = LanguageDetect.classify(recognized)
        if kind == .garbage || kind == .empty {
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

        let offline = translateOffline(recognized: recognized)
        if offline.matched { return offline }

        guard settings.geminiEnabledAndReady else {
            var o = offline
            if settings.useGemini && !settings.hasGeminiKey {
                o.geminiErrorRU = "Нет ключа Gemini в Настройках"
            } else if !settings.useGemini {
                o.geminiErrorRU = "Включи Gemini в Настройках"
            }
            return o
        }

        let hint: TranslateSourceHint = kind == .russian ? .ru : .en
        do {
            return try await GeminiSiteCoachService.shared.translateThrowing(
                text: recognized,
                sourceHint: hint
            )
        } catch let e as GeminiRequestError {
            var o = offline
            o.geminiErrorRU = e.shortRU
            return o
        } catch {
            var o = offline
            o.geminiErrorRU = "Нет сети / таймаут Gemini"
            return o
        }
    }

    /// Public for Translator STT locale + auto RU↔EN direction.
    static func isMostlyRussian(_ text: String) -> Bool {
        LanguageDetect.isMostlyRussian(text)
    }

    /// One clean locale per pass. Empty → RU speech; Cyrillic draft → EN mic; Latin → RU mic.
    static func translatorMicLocaleId(draftOrInput: String, englishLocale: String) -> String {
        let t = draftOrInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "ru-RU" }
        switch LanguageDetect.classify(t) {
        case .russian: return englishLocale
        case .english: return "ru-RU"
        case .garbage, .empty: return "ru-RU"
        }
    }
}
