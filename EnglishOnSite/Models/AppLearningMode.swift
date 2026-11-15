import Foundation
import SwiftUI

/// Top-level app track: On site vs Regular Language (shared across all tabs).
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

    /// Short label for segmented pickers (all tabs).
    var pickerLabel: String {
        switch self {
        case .onSite: return "On-site"
        case .regular: return "Regular"
        }
    }

    var blurbRU: String {
        switch self {
        case .onSite:
            return "Language on Site · объект / стройка / CCTV"
        case .regular:
            return "Regular Language · быт, еда, поездки, dating…"
        }
    }

    var tutorMode: TutorContentMode {
        switch self {
        case .onSite: return .site
        case .regular: return .general
        }
    }

    static func from(tutor mode: TutorContentMode) -> AppLearningMode {
        switch mode {
        case .site: return .onSite
        case .general: return .regular
        }
    }
}

/// Uniform On-site | Regular switch — same control on Уроки / Фразовые / Мои фразы / Репетитор.
struct LearningModePicker: View {
    @Binding var mode: AppLearningMode
    var showsBlurb: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Режим", selection: $mode) {
                ForEach(AppLearningMode.allCases) { m in
                    Text(m.pickerLabel).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("On-site или Regular English")

            if showsBlurb {
                Text(mode.blurbRU)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
