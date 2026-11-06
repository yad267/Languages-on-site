import Foundation

enum SpeechLangKind: Equatable {
    case empty
    case russian
    case english
    case garbage
}

enum LanguageDetect {
    /// Clean RU / clean EN / mixed STT garbage («Ай Don't Hell»).
    static func classify(_ text: String) -> SpeechLangKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return .empty }

        let cyr = letters.filter { (0x0400...0x04FF).contains($0.value) }.count
        let lat = letters.count - cyr
        let cyrRatio = Double(cyr) / Double(letters.count)

        // Mixed scripts in one short utterance → almost always STT locale mash.
        if cyr >= 2, lat >= 2, cyrRatio > 0.12, cyrRatio < 0.88 {
            return .garbage
        }

        // Latin that looks like broken RU-with-EN (common en-locale hearing Russian).
        let lower = trimmed.lowercased()
        let garbageHints = ["ай don't", "ай dont", "don't hell", "i hell", "ай i ", "hell ", " ай"]
        if lat > 0, cyr > 0, garbageHints.contains(where: { lower.contains($0) }) {
            return .garbage
        }

        if cyr * 2 >= letters.count { return .russian }
        return .english
    }

    static func isMostlyRussian(_ text: String) -> Bool {
        classify(text) == .russian
    }
}
