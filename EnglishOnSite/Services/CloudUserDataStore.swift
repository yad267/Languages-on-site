import Foundation
import SwiftData

/// Private CloudKit-backed store for all user-created / user-changed data beyond LibraryItem.
/// SwiftData writes locally always; CloudKit private DB syncs when the Apple ID has iCloud.
@MainActor
enum CloudUserDataStore {
    static let pairsPhrasalNS = "pairs.known.phrasal"
    static let pairsOppositesNS = "pairs.known.opposites"
    static let lessonCompletedNS = "lesson.completed"
    static let blobExtraVerbsSite = "tutor.extraVerbs.site"
    static let blobExtraVerbsGeneral = "tutor.extraVerbs.general"
    static let blobGlossCache = "tutor.glossCache"

    private static let migratedFlag = "eos.cloudUserData.migratedFromDefaults.v1"

    private(set) static var context: ModelContext?
    private static var prefsSaveTask: Task<Void, Never>?

    static weak var settingsForRemoteApply: AppSettings?

    static func configure(container: ModelContainer, settings: AppSettings? = nil) {
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = true
        context = ctx
        settingsForRemoteApply = settings
        migrateFromUserDefaultsIfNeeded()
        print("[cloud-user] configured ModelContext (private CloudKit when available)")
        // CloudKit import is async — refresh a couple of times after launch so reinstall restore lands.
        Task { @MainActor in
            for delay in [2_000_000_000, 8_000_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                PairsKnownStore.refreshFromCloud()
                LessonProgressStore.refreshFromCloud()
                TutorBankStore.refreshFromCloud()
                if let settings = settingsForRemoteApply {
                    applyCloudPrefs(to: settings)
                }
                print("[cloud-user] delayed CloudKit refresh")
            }
        }
    }

    // MARK: - Prefs

    struct PrefsPayload: Codable {
        var learningMode: String
        var englishSpeed: String
        var showTips: Bool
        var voiceCommandsJSON: String
        var rememberDuration: Int
        var translateDuration: Int
        var rememberLocale: String
        var useGemini: Bool
        var useElevenLabs: Bool
        var elModel: String
        var elStabilityEN: Double
        var elStabilityRU: Double
        var elSimilarityEN: Double
        var elSimilarityRU: Double
        var elStyleEN: Double
        var elStyleRU: Double
        var lessonsPackURL: String
        var voiceIdEnSupervisor: String
        var eosSyncWebhookURL: String
    }

    static func schedulePrefsSave(from settings: AppSettings) {
        prefsSaveTask?.cancel()
        prefsSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            savePrefs(from: settings)
        }
    }

    static func savePrefs(from settings: AppSettings) {
        guard let context else { return }
        let vcJSON: String
        if let data = try? JSONEncoder().encode(settings.voiceCommands),
           let s = String(data: data, encoding: .utf8) {
            vcJSON = s
        } else {
            vcJSON = "{}"
        }
        let payload = PrefsPayload(
            learningMode: settings.learningMode.rawValue,
            englishSpeed: settings.englishSpeed.rawValue,
            showTips: settings.showTips,
            voiceCommandsJSON: vcJSON,
            rememberDuration: settings.rememberDuration.rawValue,
            translateDuration: settings.translateDuration.rawValue,
            rememberLocale: settings.rememberLocale.rawValue,
            useGemini: settings.useGemini,
            useElevenLabs: settings.useElevenLabs,
            elModel: settings.elModel.rawValue,
            elStabilityEN: settings.elStabilityEN,
            elStabilityRU: settings.elStabilityRU,
            elSimilarityEN: settings.elSimilarityEN,
            elSimilarityRU: settings.elSimilarityRU,
            elStyleEN: settings.elStyleEN,
            elStyleRU: settings.elStyleRU,
            lessonsPackURL: settings.lessonsPackURL,
            voiceIdEnSupervisor: settings.voiceIdEnSupervisor,
            eosSyncWebhookURL: settings.eosSyncWebhookURL
        )
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let row = latestPrefs(in: context) ?? {
            let r = SyncedPrefsRecord()
            context.insert(r)
            return r
        }()
        row.payloadJSON = json
        row.updatedAt = Date()
        try? context.save()
    }

    static func applyCloudPrefs(to settings: AppSettings) {
        guard let context, let row = latestPrefs(in: context),
              let data = row.payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PrefsPayload.self, from: data) else { return }
        settings.applyCloudPayload(payload)
        print("[cloud-user] applied prefs from CloudKit/local SwiftData updatedAt=\(row.updatedAt)")
    }

    private static func latestPrefs(in context: ModelContext) -> SyncedPrefsRecord? {
        let descriptor = FetchDescriptor<SyncedPrefsRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: - Marks (pairs / lessons)

    static func markValues(namespace: String) -> Set<String> {
        guard let context else { return [] }
        let descriptor = FetchDescriptor<SyncedMarkRecord>()
        let all = (try? context.fetch(descriptor)) ?? []
        return Set(all.filter { $0.namespace == namespace }.map(\.value))
    }

    static func addMark(namespace: String, value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !v.isEmpty, let context else { return }
        if markValues(namespace: namespace).contains(v) { return }
        context.insert(SyncedMarkRecord(namespace: namespace, value: v))
        try? context.save()
    }

    static func replaceMarks(namespace: String, values: Set<String>) {
        guard let context else { return }
        let descriptor = FetchDescriptor<SyncedMarkRecord>()
        let all = (try? context.fetch(descriptor)) ?? []
        for row in all where row.namespace == namespace {
            context.delete(row)
        }
        for v in values {
            let key = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            context.insert(SyncedMarkRecord(namespace: namespace, value: key))
        }
        try? context.save()
    }

    // MARK: - Why history

    struct WhyItemDTO: Codable, Hashable {
        var q: String
        var a: String
    }

    static func loadWhyHistory() -> [WhyItemDTO] {
        guard let context else { return [] }
        let descriptor = FetchDescriptor<SyncedWhyRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.prefix(8).map { WhyItemDTO(q: $0.question, a: $0.answer) }
    }

    static func saveWhyHistory(_ items: [WhyItemDTO]) {
        guard let context else { return }
        let descriptor = FetchDescriptor<SyncedWhyRecord>()
        let existing = (try? context.fetch(descriptor)) ?? []
        for row in existing { context.delete(row) }
        for (idx, item) in items.prefix(8).enumerated() {
            let created = Date().addingTimeInterval(TimeInterval(-idx))
            context.insert(SyncedWhyRecord(question: item.q, answer: item.a, createdAt: created))
        }
        try? context.save()
    }

    // MARK: - Blobs

    static func loadBlobJSON(kind: String) -> String? {
        guard let context else { return nil }
        return latestBlob(kind: kind, in: context)?.payloadJSON
    }

    static func saveBlobJSON(kind: String, json: String) {
        guard let context else { return }
        let row = latestBlob(kind: kind, in: context) ?? {
            let r = SyncedBlobRecord(kind: kind)
            context.insert(r)
            return r
        }()
        row.payloadJSON = json
        row.updatedAt = Date()
        try? context.save()
    }

    private static func latestBlob(kind: String, in context: ModelContext) -> SyncedBlobRecord? {
        let descriptor = FetchDescriptor<SyncedBlobRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor))?.first { $0.kind == kind }
    }

    // MARK: - Migration from UserDefaults (one-shot)

    static func migrateFromUserDefaultsIfNeeded() {
        guard let context else { return }
        if UserDefaults.standard.bool(forKey: migratedFlag) {
            // Still import marks if Cloud empty but Defaults have data (partial recover).
            importMarksIfCloudEmpty()
            return
        }

        // Prefs: leave AppSettings as source; snapshot current Defaults-backed settings after configure.
        // Marks
        let phrasal = Set(UserDefaults.standard.stringArray(forKey: "eos.pairs.known.phrasal") ?? [])
        let opposites = Set(UserDefaults.standard.stringArray(forKey: "eos.pairs.known.opposites") ?? [])
        let lessons = Set(UserDefaults.standard.stringArray(forKey: "completedLessonIds_v1") ?? [])
        if markValues(namespace: pairsPhrasalNS).isEmpty, !phrasal.isEmpty {
            replaceMarks(namespace: pairsPhrasalNS, values: phrasal)
        }
        if markValues(namespace: pairsOppositesNS).isEmpty, !opposites.isEmpty {
            replaceMarks(namespace: pairsOppositesNS, values: opposites)
        }
        if markValues(namespace: lessonCompletedNS).isEmpty, !lessons.isEmpty {
            replaceMarks(namespace: lessonCompletedNS, values: lessons)
        }

        // Why
        if loadWhyHistory().isEmpty,
           let data = UserDefaults.standard.data(forKey: "tutorWhyHistory_v1"),
           let arr = try? JSONDecoder().decode([WhyItemDTO].self, from: data),
           !arr.isEmpty {
            saveWhyHistory(arr)
        }

        // Blobs
        migrateBlobIfNeeded(defaultsKey: "tutorExtraVerbs_v1", kind: blobExtraVerbsSite)
        migrateBlobIfNeeded(defaultsKey: "tutorExtraVerbs_general_v1", kind: blobExtraVerbsGeneral)
        migrateBlobIfNeeded(defaultsKey: "tutorPairsGlossCache_v1", kind: blobGlossCache)

        UserDefaults.standard.set(true, forKey: migratedFlag)
        try? context.save()
        print("[cloud-user] migrated UserDefaults → SwiftData/CloudKit")
    }

    private static func importMarksIfCloudEmpty() {
        let phrasal = Set(UserDefaults.standard.stringArray(forKey: "eos.pairs.known.phrasal") ?? [])
        if markValues(namespace: pairsPhrasalNS).isEmpty, !phrasal.isEmpty {
            replaceMarks(namespace: pairsPhrasalNS, values: phrasal)
        }
        let opposites = Set(UserDefaults.standard.stringArray(forKey: "eos.pairs.known.opposites") ?? [])
        if markValues(namespace: pairsOppositesNS).isEmpty, !opposites.isEmpty {
            replaceMarks(namespace: pairsOppositesNS, values: opposites)
        }
        let lessons = Set(UserDefaults.standard.stringArray(forKey: "completedLessonIds_v1") ?? [])
        if markValues(namespace: lessonCompletedNS).isEmpty, !lessons.isEmpty {
            replaceMarks(namespace: lessonCompletedNS, values: lessons)
        }
    }

    private static func migrateBlobIfNeeded(defaultsKey: String, kind: String) {
        guard loadBlobJSON(kind: kind) == nil,
              let data = UserDefaults.standard.data(forKey: defaultsKey),
              let json = String(data: data, encoding: .utf8), !json.isEmpty else { return }
        saveBlobJSON(kind: kind, json: json)
    }
}
