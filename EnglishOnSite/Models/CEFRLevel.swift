import Foundation

/// Shared CEFR A1…C2 for Onsite + Regular banks.
enum CEFRLevel: String, CaseIterable, Identifiable, Hashable, Codable {
    case a1 = "A1"
    case a2 = "A2"
    case b1 = "B1"
    case b2 = "B2"
    case c1 = "C1"
    case c2 = "C2"

    var id: String { rawValue }

    var titleRU: String {
        switch self {
        case .a1: return "A1 · старт"
        case .a2: return "A2 · база"
        case .b1: return "B1 · увереннее"
        case .b2: return "B2 · сложнее"
        case .c1: return "C1 · продвинутый"
        case .c2: return "C2 · почти носитель"
        }
    }

    var blurbRU: String {
        switch self {
        case .a1: return "Только A1 — без уровней выше"
        case .a2: return "Только A2 — без B/C"
        case .b1: return "Только B1 — без B2/C"
        case .b2: return "Только B2 — без C"
        case .c1: return "Только C1 — без C2"
        case .c2: return "Только C2"
        }
    }

    /// Coarse bands for lesson browsing (A1–A2 / B1–B2 / C).
    enum Band: String, CaseIterable, Identifiable, Hashable {
        case all
        case a1a2
        case b1b2
        case c

        var id: String { rawValue }

        var titleRU: String {
            switch self {
            case .all: return "Все"
            case .a1a2: return "A1–A2"
            case .b1b2: return "B1–B2"
            case .c: return "C1–C2"
            }
        }

        var subtitleRU: String {
            switch self {
            case .all: return "Все уровни"
            case .a1a2: return "Простые фразы"
            case .b1b2: return "На площадке"
            case .c: return "Сложнее"
            }
        }

        func contains(_ level: CEFRLevel?) -> Bool {
            guard let level else {
                // Untagged legacy lessons sit in the mid band.
                return self == .all || self == .b1b2
            }
            switch self {
            case .all: return true
            case .a1a2: return level == .a1 || level == .a2
            case .b1b2: return level == .b1 || level == .b2
            case .c: return level == .c1 || level == .c2
            }
        }
    }

    static func parse(_ raw: String?) -> CEFRLevel? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return CEFRLevel(rawValue: t)
    }
}
