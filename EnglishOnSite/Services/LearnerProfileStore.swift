import Foundation
import Observation

/// Local + CloudKit blob persistence for `LearnerProfile`.
/// Pitfall: never block first paint — load sync from UserDefaults, refresh cloud after yield.
@MainActor
@Observable
final class LearnerProfileStore {
    static let shared = LearnerProfileStore()

    private static let defaultsKey = "eos.learnerProfile.v1"
    private static let cloudKind = "learner.profile.v1"

    private(set) var profile: LearnerProfile = .default

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey) {
            let iso = JSONDecoder()
            iso.dateDecodingStrategy = .iso8601
            if let decoded = (try? iso.decode(LearnerProfile.self, from: data))
                ?? (try? JSONDecoder().decode(LearnerProfile.self, from: data)) {
                profile = decoded
            }
        }
    }

    func refreshFromCloud() {
        guard let json = CloudUserDataStore.loadBlobJSON(kind: Self.cloudKind),
              let data = json.data(using: .utf8) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        // Fallback: older blobs may use default Date encoding.
        let remote: LearnerProfile
        if let r = try? dec.decode(LearnerProfile.self, from: data) {
            remote = r
        } else if let r = try? JSONDecoder().decode(LearnerProfile.self, from: data) {
            remote = r
        } else {
            return
        }
        // Prefer newer timestamp (pitfall: reinstall / dual device).
        if remote.updatedAt > profile.updatedAt || !profile.isSet {
            profile = remote
            persistLocalOnly(remote)
        }
    }

    func save(_ newValue: LearnerProfile, applyLearningModeTo settings: AppSettings? = nil) {
        var value = newValue
        value.updatedAt = Date()
        profile = value
        persistLocalOnly(value)
        // Pitfall: Date JSON must round-trip across devices — use ISO8601, not reference date.
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(value),
           let json = String(data: data, encoding: .utf8) {
            CloudUserDataStore.saveBlobJSON(kind: Self.cloudKind, json: json)
        }
        if let settings {
            let mode = value.role.preferredLearningMode
            // Pitfall: never flip Onsite/Regular when role still unknown.
            if settings.learningMode != mode, value.role != .unknown {
                settings.learningMode = mode
            }
            TutorBankStore.setMode(value.role.tutorMode)
        }
    }

    func clear(settings: AppSettings? = nil) {
        // Reset without forcing learning mode — user may stay on current tab.
        save(.default, applyLearningModeTo: nil)
        _ = settings
    }

    /// Rank section list for Home — unknown profile keeps pack order.
    func rankedSections(_ sections: [LessonSectionInfo]) -> [LessonSectionInfo] {
        var preferred = profile.role.preferredSectionIds
        // Fastener/tool-heavy intros → surface Tools before generic electrical.
        if !profile.tools.isEmpty {
            preferred = ["tools"] + preferred.filter { $0 != "tools" }
        }
        guard !preferred.isEmpty else { return sections }
        var rank: [String: Int] = [:]
        for (i, id) in preferred.enumerated() { rank[id] = i }
        return sections.sorted { a, b in
            let ra = rank[a.id] ?? 1_000
            let rb = rank[b.id] ?? 1_000
            if ra != rb { return ra < rb }
            return a.titleRu < b.titleRu
        }
    }

    /// Auto-build + save profile from a free-text introduction (first open / voice).
    @discardableResult
    func applyIntroduction(_ raw: String, settings: AppSettings?) -> LearnerProfile {
        let inferred = LearnerProfile.infer(from: raw, base: profile.isSet ? profile : .default)
        save(inferred, applyLearningModeTo: settings)
        return inferred
    }

    /// First lesson matching the current profile — for instant post-intro jump.
    func firstRecommendedLesson() -> Lesson? {
        let mode = profile.role == .unknown ? AppLearningMode.onSite : profile.role.preferredLearningMode
        let sections = rankedSections(SectionLessonStore.sections(track: mode))
        guard let section = sections.first else { return nil }
        let band: CEFRLevel.Band = {
            switch profile.cefr {
            case .a1, .a2: return .a1a2
            case .b1, .b2: return .b1b2
            case .c1, .c2: return .c
            case nil: return .all
            }
        }()
        let lessons = SectionLessonStore.lessons(sectionId: section.id, track: mode)
            .filter { band.contains($0.cefrLevel) }
        return lessons.first ?? SectionLessonStore.lessons(sectionId: section.id, track: mode).first
    }

    /// CEFR band for browsing lists (defaults to all when unset).
    var preferredBand: CEFRLevel.Band {
        switch profile.cefr {
        case .a1, .a2: return .a1a2
        case .b1, .b2: return .b1b2
        case .c1, .c2: return .c
        case nil: return .all
        }
    }

    private func persistLocalOnly(_ value: LearnerProfile) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(value) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
