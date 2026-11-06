import Foundation

struct LearningBankEntry: Identifiable, Hashable {
    var id: String { LibraryItem.normalizeEN(en) + "|" + type.rawValue }
    let en: String
    let ru: String
    let example: String
    let meta: String
    let type: LibraryItemType
}

/// Bundled words / site phrasals / sentences (from CSV → JSON). Progress lives in LibraryItem.
enum LearningBankStore {
    private struct Pack: Codable {
        let version: Int?
        let items: [Row]
    }

    private struct Row: Codable {
        let en: String
        let ru: String?
        let example: String?
        let part_of_speech: String?
        let category: String?
    }

    static func words() -> [LearningBankEntry] {
        load(resource: "learning_words_v1", type: .word) { row in
            LearningBankEntry(
                en: row.en,
                ru: row.ru ?? "",
                example: row.example ?? "",
                meta: row.part_of_speech ?? "",
                type: .word
            )
        }
    }

    static func sitePhrasals() -> [LearningBankEntry] {
        load(resource: "learning_phrasals_site_v1", type: .phrasal) { row in
            LearningBankEntry(
                en: row.en,
                ru: row.ru ?? "",
                example: row.example ?? "",
                meta: row.category ?? "site",
                type: .phrasal
            )
        }
    }

    static func sentences() -> [LearningBankEntry] {
        load(resource: "learning_sentences_v1", type: .sentence) { row in
            LearningBankEntry(
                en: row.en,
                ru: row.ru ?? "",
                example: "",
                meta: row.category ?? "",
                type: .sentence
            )
        }
    }

    private static func load(
        resource: String,
        type: LibraryItemType,
        map: (Row) -> LearningBankEntry
    ) -> [LearningBankEntry] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let pack = try? JSONDecoder().decode(Pack.self, from: data) else {
            return []
        }
        return pack.items
            .map(map)
            .filter { !$0.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
