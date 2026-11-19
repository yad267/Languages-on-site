import Foundation
import Observation

/// Persists auto-created folders and lesson→category membership for user lessons.
@Observable
@MainActor
final class UserLessonCatalogStore {
    static let shared = UserLessonCatalogStore()

    private(set) var categories: [UserLessonCategory] = []
    /// lessonId → categoryId
    private(set) var membership: [String: String] = [:]

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("UserLessonCatalog", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("catalog.json")
    }

    init() {
        load()
    }

    func category(forLessonId id: String) -> UserLessonCategory? {
        guard let cid = membership[id] else { return nil }
        return categories.first { $0.id == cid }
    }

    func lessons(in categoryId: String, from repository: LessonRepository) -> [Lesson] {
        let ids = Set(membership.filter { $0.value == categoryId }.map(\.key))
        return repository.lessons.filter { ids.contains($0.id) || $0.categoryId == categoryId }
    }

    /// Ensure folder exists for topic/text; return it.
    @discardableResult
    func ensureCategory(forText raw: String) -> UserLessonCategory {
        let hit = TopicCategoryClassifier.classify(raw)
        if let existing = categories.first(where: { $0.id == hit.id }) {
            return existing
        }
        let cat = TopicCategoryClassifier.category(from: hit)
        categories.append(cat)
        categories.sort { $0.titleRu.localizedCaseInsensitiveCompare($1.titleRu) == .orderedAscending }
        save()
        return cat
    }

    func assign(lessonId: String, category: UserLessonCategory) {
        if !categories.contains(where: { $0.id == category.id }) {
            categories.append(category)
            categories.sort { $0.titleRu.localizedCaseInsensitiveCompare($1.titleRu) == .orderedAscending }
        }
        membership[lessonId] = category.id
        save()
    }

    func removeLesson(id: String) {
        membership.removeValue(forKey: id)
        save()
    }

    /// Backfill membership from lessons that already carry categoryId.
    func sync(from lessons: [Lesson]) {
        var changed = false
        for lesson in lessons where lesson.isUserLesson {
            if let cid = lesson.categoryId, !cid.isEmpty {
                if membership[lesson.id] != cid {
                    membership[lesson.id] = cid
                    changed = true
                }
                if !categories.contains(where: { $0.id == cid }) {
                    let title = lesson.categoryTitleRu ?? TopicCategoryClassifier.presets.first(where: { $0.id == cid })?.titleRu ?? cid
                    let en = TopicCategoryClassifier.presets.first(where: { $0.id == cid })?.titleEn ?? cid
                    categories.append(UserLessonCategory(id: cid, titleRu: title, titleEn: en, createdAt: Date()))
                    changed = true
                }
            }
        }
        if changed {
            categories.sort { $0.titleRu.localizedCaseInsensitiveCompare($1.titleRu) == .orderedAscending }
            save()
        }
    }

    private struct Disk: Codable {
        var categories: [UserLessonCategory]
        var membership: [String: String]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let disk = try? JSONDecoder().decode(Disk.self, from: data) else {
            categories = []
            membership = [:]
            return
        }
        categories = disk.categories
        membership = disk.membership
    }

    private func save() {
        let disk = Disk(categories: categories, membership: membership)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(disk) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
