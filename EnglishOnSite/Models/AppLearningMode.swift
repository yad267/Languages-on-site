import Foundation

/// Top-level app track on Уроки: On site vs Regular Language.
enum AppLearningMode: String, CaseIterable, Identifiable, Hashable {
    case onSite
    case regular

    var id: String { rawValue }

    /// Full name (nav title / memory).
    var title: String {
        switch self {
        case .onSite: return "Language on Site"
        case .regular: return "Regular Language"
        }
    }

    /// Short label for the top Lessons picker.
    var pickerLabel: String {
        switch self {
        case .onSite: return "On site"
        case .regular: return "Regular Language"
        }
    }

    var blurbRU: String {
        switch self {
        case .onSite:
            return "Language on Site · CEFR A1–C2 · фразовые, фразы, предложения"
        case .regular:
            return "Regular Language · фразовые · лёгкие фразы · диалоги (A1–C2)"
        }
    }
}
