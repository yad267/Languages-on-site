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
}
