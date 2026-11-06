import SwiftUI

struct CoachSourceBadge: View {
    enum Kind {
        case offline
        case gemini
        case analyzing

        var title: String {
            switch self {
            case .offline: return "Офлайн"
            case .gemini: return "Gemini"
            case .analyzing: return "Разбираю…"
            }
        }

        var color: Color {
            switch self {
            case .offline: return .secondary
            case .gemini: return .accentColor
            case .analyzing: return .orange
            }
        }
    }

    let kind: Kind

    var body: some View {
        Text(kind.title)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(kind.color)
            .background(kind.color.opacity(0.12))
            .clipShape(Capsule())
    }
}
