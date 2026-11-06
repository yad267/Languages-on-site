import Foundation
import SwiftData

enum LibrarySource: String, Codable, CaseIterable {
    case remember
    case translate
    case lesson
    case manual
    case importText
    case pairsMic
    case speak
    case roleplay
    case bank
}

enum LibraryTag: String, Codable, CaseIterable, Identifiable {
    case electrical
    case cctv
    case sockets
    case safety
    case tools
    case other

    var id: String { rawValue }

    var titleRu: String {
        switch self {
        case .electrical: return "electrical"
        case .cctv: return "cctv"
        case .sockets: return "sockets"
        case .safety: return "safety"
        case .tools: return "tools"
        case .other: return "other"
        }
    }
}

/// B20 learning unit kinds in one SwiftData base.
enum LibraryItemType: String, Codable, CaseIterable, Identifiable {
    case word
    case phrasal
    case sentence
    case myPhrase

    var id: String { rawValue }

    var titleRu: String {
        switch self {
        case .word: return "слово"
        case .phrasal: return "фразовый"
        case .sentence: return "предложение"
        case .myPhrase: return "моя фраза"
        }
    }
}

@Model
final class LibraryItem {
    var id: UUID
    var createdAt: Date
    var sourceRaw: String
    var en: String
    var ru: String
    var tipRu: String
    var tagRaw: String
    var transcriptRaw: String?
    var learnedCount: Int
    var nextReviewAt: Date
    var starred: Bool
    /// B20: marked known — not in «new» rotation.
    var known: Bool
    var knownAt: Date?
    /// B21 SRS stage: 0 none · 1 → +1d · 2 → +7d · 3 → +30d
    var srsStage: Int
    /// B17b: stable audio file name under Application Support/MyPhrasesAudio/
    var audioFileName: String?
    /// Also keep EL cache key fingerprint when useful.
    var audioCacheKey: String?
    var itemTypeRaw: String
    /// Normalized EN key for dedupe (site∩general one known).
    var normalizedKey: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        source: LibrarySource,
        en: String,
        ru: String,
        tipRu: String = "",
        tag: LibraryTag = .other,
        transcriptRaw: String? = nil,
        learnedCount: Int = 0,
        nextReviewAt: Date = Date(),
        starred: Bool = false,
        known: Bool = false,
        knownAt: Date? = nil,
        srsStage: Int = 0,
        audioFileName: String? = nil,
        audioCacheKey: String? = nil,
        itemType: LibraryItemType = .myPhrase,
        normalizedKey: String = ""
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceRaw = source.rawValue
        self.en = en
        self.ru = ru
        self.tipRu = tipRu
        self.tagRaw = tag.rawValue
        self.transcriptRaw = transcriptRaw
        self.learnedCount = learnedCount
        self.nextReviewAt = nextReviewAt
        self.starred = starred
        self.known = known
        self.knownAt = knownAt
        self.srsStage = srsStage
        self.audioFileName = audioFileName
        self.audioCacheKey = audioCacheKey
        self.itemTypeRaw = itemType.rawValue
        let key = normalizedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.normalizedKey = key.isEmpty ? Self.normalizeEN(en) : key
    }

    var source: LibrarySource {
        get { LibrarySource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    var tag: LibraryTag {
        get { LibraryTag(rawValue: tagRaw) ?? .other }
        set { tagRaw = newValue.rawValue }
    }

    var itemType: LibraryItemType {
        get { LibraryItemType(rawValue: itemTypeRaw) ?? .myPhrase }
        set { itemTypeRaw = newValue.rawValue }
    }

    var isDue: Bool { nextReviewAt <= Date() }

    /// Studying pool: not yet known.
    var isLearningNew: Bool { !known }

    static func normalizeEN(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// B21: after «Знаю» / successful review — 1 → 7 → 30 days.
    func markLearned() {
        markKnown(advanceSRS: true)
    }

    func markKnown(advanceSRS: Bool = true) {
        known = true
        if knownAt == nil { knownAt = Date() }
        if advanceSRS {
            if srsStage < 1 {
                srsStage = 1
            } else if srsStage < 3 {
                srsStage += 1
            }
            learnedCount = max(learnedCount, srsStage)
            nextReviewAt = Self.dateByAdding(days: Self.intervalDays(for: srsStage), to: Date())
        } else if srsStage < 1 {
            srsStage = 1
            learnedCount = 1
            nextReviewAt = Self.dateByAdding(days: 1, to: Date())
        }
    }

    /// Remove from «Изученные» → back into Учу rotation.
    func unmarkKnown() {
        known = false
        knownAt = nil
        srsStage = 0
        learnedCount = 0
        nextReviewAt = Date()
    }

    /// Wrong on review → reset toward start (+1 day).
    func markReviewFailed() {
        known = true
        srsStage = 1
        learnedCount = max(1, learnedCount)
        nextReviewAt = Self.dateByAdding(days: 1, to: Date())
    }

    static func intervalDays(for stage: Int) -> Int {
        switch stage {
        case 1: return 1
        case 2: return 7
        default: return 30
        }
    }

    private static func dateByAdding(days: Int, to date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }
}
