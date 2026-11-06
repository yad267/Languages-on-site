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
}
