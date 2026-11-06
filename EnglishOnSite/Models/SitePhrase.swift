import Foundation

struct SitePhrase: Codable, Identifiable, Hashable {
    var id: String { "\(en.lowercased())|\(ru)" }
    let en: String
    let ru: String
    let tag: String
    let tipRu: String

    enum CodingKeys: String, CodingKey {
        case en, ru, tag
        case tipRu = "tip_ru"
    }

    var libraryTag: LibraryTag {
        LibraryTag(rawValue: tag) ?? .other
    }
}

enum PhraseBank {
    private static var cached: [SitePhrase]?

    static func all() -> [SitePhrase] {
        if let cached { return cached }
        guard let url = Bundle.main.url(forResource: "SitePhraseBank", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SitePhrase].self, from: data) else {
            cached = []
            return []
        }
        cached = decoded
        return decoded
    }

    static func phrasesFromLessons() -> [SitePhrase] {
        var out: [SitePhrase] = []
        // Bundle only here (sync, no MainActor) — user lessons stay in repository UI
        for lesson in LessonLoader.loadBundle() {
            let tag = lesson.tags.first.flatMap { LibraryTag(rawValue: $0)?.rawValue } ?? "safety"
            for card in lesson.cards {
                out.append(SitePhrase(en: card.en, ru: card.ru, tag: tag, tipRu: ""))
            }
            for line in lesson.lines {
                out.append(SitePhrase(en: line.en, ru: line.ru, tag: tag, tipRu: line.tipRu ?? ""))
            }
            for say in lesson.sayToday {
                out.append(SitePhrase(en: say.en, ru: say.ru, tag: tag, tipRu: ""))
            }
        }
        return out
    }

    static func searchBank(normalized: String) -> SitePhrase? {
        let q = normalize(normalized)
        guard !q.isEmpty else { return nil }
        let pool = all() + phrasesFromLessons()

        if let exact = pool.first(where: { normalize($0.en) == q || normalize($0.ru) == q }) {
            return exact
        }

        // Almost exact: contains / contained
        if let near = pool.first(where: {
            let en = normalize($0.en)
            let ru = normalize($0.ru)
            return (!en.isEmpty && (en.contains(q) || q.contains(en)))
                || (!ru.isEmpty && (ru.contains(q) || q.contains(ru)))
        }) {
            return near
        }

        // Token overlap for EN
        let qTokens = Set(q.split(separator: " ").map(String.init).filter { $0.count > 2 })
        guard !qTokens.isEmpty else { return nil }
        var best: (SitePhrase, Int)?
        for p in pool {
            let tokens = Set(normalize(p.en).split(separator: " ").map(String.init))
            let score = qTokens.intersection(tokens).count
            if score >= 2, score > (best?.1 ?? 0) {
                best = (p, score)
            }
        }
        return best?.0
    }

    static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "[^a-zа-яё0-9'\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0400...0x04FF).contains(scalar.value)
        }
    }

    static func containsLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value)
        }
    }
}
