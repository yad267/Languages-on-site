import Foundation

struct CanonPhrase: Equatable {
    let en: String
    let ru: String
    let tipRu: String
    let sourceIsRussian: Bool
    let viaGemini: Bool
}

/// B17: raw RU/EN (voice or text) → conversational correct EN + RU. Never save raw STT as canon.
enum MyPhraseCanonService {
    static func canonize(
        raw: String,
        settings: AppSettings,
        phrasalHint: String? = nil
    ) async throws -> CanonPhrase {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { throw CanonError.tooShort }

        let kind = LanguageDetect.classify(trimmed)
        switch kind {
        case .empty, .garbage:
            throw CanonError.unclear
        case .russian, .english:
            break
        }

        if settings.geminiEnabledAndReady {
            do {
                return try await GeminiSiteCoachService.shared.canonizePhrase(
                    text: trimmed,
                    sourceIsRussian: kind == .russian,
                    phrasalHint: phrasalHint
                )
            } catch {
                if let offline = offlineFallback(trimmed, kind: kind) { return offline }
                throw error
            }
        }

        if let offline = offlineFallback(trimmed, kind: kind) { return offline }
        throw CanonError.needGemini
    }

    private static func offlineFallback(_ text: String, kind: SpeechLangKind) -> CanonPhrase? {
        if let hit = PhraseBank.searchBank(normalized: text) {
            return CanonPhrase(
                en: hit.en,
                ru: hit.ru,
                tipRu: hit.tipRu,
                sourceIsRussian: kind == .russian,
                viaGemini: false
            )
        }
        // EN typed cleanly — keep as canon, RU stub for later.
        if kind == .english, text.split(separator: " ").count >= 2 {
            return CanonPhrase(
                en: text,
                ru: "(перевод позже)",
                tipRu: "",
                sourceIsRussian: false,
                viaGemini: false
            )
        }
        return nil
    }

    enum CanonError: LocalizedError {
        case tooShort, unclear, needGemini

        var errorDescription: String? {
            switch self {
            case .tooShort: return "Слишком коротко"
            case .unclear: return "Не расслышал — скажи ещё раз"
            case .needGemini: return "Нужен Gemini в Настройках для канона"
            }
        }
    }
}
