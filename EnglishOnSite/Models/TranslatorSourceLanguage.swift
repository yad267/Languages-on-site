import Foundation

/// Source language for the translator mic + Gemini direction.
/// Target for display is always Russian (app audience).
enum TranslatorSourceLanguage: String, CaseIterable, Identifiable, Codable {
    case english
    case spanish
    case german
    case french
    case portuguese

    var id: String { rawValue }

    var titleRU: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .portuguese: return "Português"
        }
    }

    var shortCode: String {
        switch self {
        case .english: return "EN"
        case .spanish: return "ES"
        case .german: return "DE"
        case .french: return "FR"
        case .portuguese: return "PT"
        }
    }

    /// SFSpeech locale id. English follows Remember locale (IE/GB).
    func speechLocaleId(englishLocale: String) -> String {
        switch self {
        case .english: return englishLocale
        case .spanish: return "es-ES"
        case .german: return "de-DE"
        case .french: return "fr-FR"
        case .portuguese: return "pt-PT"
        }
    }

    /// Same-language Speech fallbacks only — never cross into another tongue.
    func speechLocaleFallbacks(englishLocale: String) -> [String] {
        switch self {
        case .english:
            return [englishLocale, "en-IE", "en-GB", "en-US"]
        case .spanish:
            return ["es-ES", "es-MX", "es-US"]
        case .german:
            return ["de-DE", "de-AT", "de-CH"]
        case .french:
            return ["fr-FR", "fr-CA", "fr-BE"]
        case .portuguese:
            return ["pt-PT", "pt-BR"]
        }
    }

    /// Hint for Gemini prompts / TranslationService.
    var geminiSourceHint: String {
        switch self {
        case .english: return "en"
        case .spanish: return "es"
        case .german: return "de"
        case .french: return "fr"
        case .portuguese: return "pt"
        }
    }

    var promptLanguageName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Spanish"
        case .german: return "German"
        case .french: return "French"
        case .portuguese: return "Portuguese"
        }
    }
}
