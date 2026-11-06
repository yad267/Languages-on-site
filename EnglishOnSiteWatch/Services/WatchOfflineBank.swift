import Foundation

struct WatchPhrase: Codable, Identifiable {
    var id: String { "\(en)|\(ru)" }
    let en: String
    let ru: String
    let tag: String
    let tipRu: String

    enum CodingKeys: String, CodingKey {
        case en, ru, tag
        case tipRu = "tip_ru"
    }
}

enum WatchOfflineBank {
    private static var cached: [WatchPhrase]?

    static func all() -> [WatchPhrase] {
        if let cached { return cached }
        guard let url = Bundle.main.url(forResource: "WatchPhraseBank", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([WatchPhrase].self, from: data) else {
            cached = []
            return []
        }
        cached = decoded
        return decoded
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-zа-яё0-9'\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func lookup(_ text: String) -> WatchPhrase? {
        let q = normalize(text)
        guard !q.isEmpty else { return nil }
        let pool = all()
        if let exact = pool.first(where: { normalize($0.en) == q || normalize($0.ru) == q }) {
            return exact
        }
        return pool.first(where: {
            let en = normalize($0.en)
            let ru = normalize($0.ru)
            return (!en.isEmpty && (en.contains(q) || q.contains(en)))
                || (!ru.isEmpty && (ru.contains(q) || q.contains(ru)))
        })
    }

    static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }
}
