import Foundation

/// Where a personal speech term was first (or also) heard.
enum SpeechTermSource: String, Codable, Hashable, CaseIterable {
    case introduction
    case topic
    case document
    case photo
    case manual

    var labelRU: String {
        switch self {
        case .introduction: return "introduction"
        case .topic: return "тема"
        case .document: return "документ"
        case .photo: return "фото"
        case .manual: return "вручную"
        }
    }
}

/// One personal dictionary row — Cyrillic slang the learner actually says.
struct LearnerSpeechTermEntry: Codable, Hashable, Identifiable {
    /// Stable merge key = spoken.lowercased().
    var id: String
    /// Display / ASR form (джигсо, бенсоу, трей…).
    var spoken: String
    /// Optional EN gloss for Gemini (tray / jigsaw) — never shown in intro transcript.
    var enHint: String?
    var aliases: [String]
    /// Sources that contributed this term (merge unions them).
    var sources: [SpeechTermSource]
    var addedAt: Date
    var updatedAt: Date
    var hitCount: Int

    init(
        spoken: String,
        enHint: String? = nil,
        aliases: [String] = [],
        source: SpeechTermSource,
        now: Date = Date()
    ) {
        let form = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = form.lowercased()
        self.spoken = form
        self.enHint = enHint
        self.aliases = aliases
        self.sources = [source]
        self.addedAt = now
        self.updatedAt = now
        self.hitCount = 1
    }

    /// Merge by id: keep spoken, union aliases/sources, bump hits, never drop old data.
    static func merge(existing: LearnerSpeechTermEntry, incoming: LearnerSpeechTermEntry) -> LearnerSpeechTermEntry {
        var out = existing
        if out.spoken.isEmpty { out.spoken = incoming.spoken }
        if (out.enHint == nil || out.enHint?.isEmpty == true), let hint = incoming.enHint, !hint.isEmpty {
            out.enHint = hint
        }
        var aliasSet = Set(out.aliases.map { $0.lowercased() })
        for a in incoming.aliases {
            let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, aliasSet.insert(t.lowercased()).inserted else { continue }
            out.aliases.append(t)
        }
        var sourceSet = Set(out.sources)
        for s in incoming.sources where sourceSet.insert(s).inserted {
            out.sources.append(s)
        }
        out.hitCount = max(1, out.hitCount) + max(1, incoming.hitCount)
        out.updatedAt = max(out.updatedAt, incoming.updatedAt)
        out.addedAt = min(out.addedAt, incoming.addedAt)
        return out
    }

    static func mergeAll(_ batches: [[LearnerSpeechTermEntry]]) -> [LearnerSpeechTermEntry] {
        var map: [String: LearnerSpeechTermEntry] = [:]
        for batch in batches {
            for entry in batch {
                let key = entry.id.lowercased()
                if let old = map[key] {
                    map[key] = merge(existing: old, incoming: entry)
                } else {
                    map[key] = entry
                }
            }
        }
        return map.values.sorted { $0.spoken.localizedCaseInsensitiveCompare($1.spoken) == .orderedAscending }
    }
}
