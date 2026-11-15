import Foundation

/// Remote / bundled lessons pack (Drive-friendly).
struct LessonPack: Codable {
    var schema: Int
    var contentVersion: Int
    var title: String?
    var lessons: [Lesson]

    enum CodingKeys: String, CodingKey {
        case schema
        case contentVersion = "content_version"
        case title
        case lessons
    }
}

enum LessonProgressStore {
    private static let key = "completedLessonIds_v1"

    static var completedIds: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: key)
            Task { @MainActor in
                CloudUserDataStore.replaceMarks(
                    namespace: CloudUserDataStore.lessonCompletedNS,
                    values: newValue
                )
            }
        }
    }

    static func isCompleted(_ id: String) -> Bool {
        completedIds.contains(id)
    }

    static func markCompleted(_ id: String) {
        var s = completedIds
        s.insert(id)
        completedIds = s
    }

    /// Pull CloudKit / SwiftData completed lessons into UserDefaults cache.
    @MainActor
    static func refreshFromCloud() {
        let cloud = CloudUserDataStore.markValues(namespace: CloudUserDataStore.lessonCompletedNS)
        if !cloud.isEmpty {
            UserDefaults.standard.set(Array(cloud).sorted(), forKey: key)
        }
    }
}
