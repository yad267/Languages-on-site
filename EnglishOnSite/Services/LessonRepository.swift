import Foundation
import Observation

/// Path lessons from LessonStore (pack) + optional user-created lessons.
@Observable
@MainActor
final class LessonRepository {
    static let shared = LessonRepository()

    private(set) var lessons: [Lesson] = []
    private let store = LessonStore.shared

    private var userDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("UserLessons", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    init() {
        reload()
    }

    func listAll() -> [Lesson] { lessons }

    func reload() {
        store.reloadLocal()
        let pack = store.lessons
        let user = loadUserLessons()
        lessons = pack + user
    }

    func saveUser(_ lesson: Lesson) throws {
        let validated = lesson.validated() ?? lesson
        guard validated.validated() != nil else {
            throw LessonRepositoryError.invalidLesson
        }
        let url = userDirectory.appendingPathComponent("\(validated.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(validated)
        try data.write(to: url, options: .atomic)
        reload()
    }

    func deleteUser(id: String) throws {
        guard id.hasPrefix("user-") || lessons.first(where: { $0.id == id })?.isUserLesson == true else {
            throw LessonRepositoryError.cannotDeleteBundle
        }
        let url = userDirectory.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        reload()
    }

    func isUserLesson(_ lesson: Lesson) -> Bool { lesson.isUserLesson }

    /// Short offline stubs when Gemini is off (optional path).
    static func stubTemplates() -> [Lesson] {
        [
            stub(
                id: "stub-tray-run",
                title: "Tray на трассе (шаблон)",
                tags: ["electrical", "containment"],
                scene: "Подвеска tray к щитовой.",
                topic: "cable tray",
                lines: [
                    .init(en: "We need cable tray to the plant room.", ru: "Нужен tray до щитовой.", role: "foreman"),
                    .init(en: "Basket or tray?", ru: "Basket или tray?", role: "electrician", practice: true),
                    .init(en: "Tray on the main run.", ru: "Tray на основной трассе.", role: "foreman"),
                    .init(en: "How many metres of tray?", ru: "Сколько метров tray?", role: "electrician", practice: true),
                ],
                say: [
                    .init(en: "Basket or tray?", ru: "Basket или tray?"),
                    .init(en: "How many metres of tray?", ru: "Сколько метров tray?"),
                ]
            ),
        ]
    }

    private func loadUserLessons() -> [Lesson] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: userDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let jsons = files.filter { $0.pathExtension.lowercased() == "json" }
        let sorted = jsons.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }

        return sorted.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let lesson = try? JSONDecoder().decode(Lesson.self, from: data),
                  lesson.validated() != nil else { return nil }
            return lesson
        }
    }

    private static func stub(
        id: String,
        title: String,
        tags: [String],
        scene: String,
        topic: String,
        lines: [LessonLine],
        say: [SayTodayPhrase]
    ) -> Lesson {
        Lesson(
            id: id,
            titleRu: title,
            tags: tags,
            sceneRu: scene,
            yourRole: "electrician",
            partnerRole: "foreman",
            lines: lines,
            sayToday: say,
            createdBy: "stub",
            topicRaw: topic
        )
    }
}

enum LessonRepositoryError: LocalizedError {
    case invalidLesson
    case cannotDeleteBundle

    var errorDescription: String? {
        switch self {
        case .invalidLesson: return "Не собралось, попробуй короче тему"
        case .cannotDeleteBundle: return "Встроенный урок нельзя удалить"
        }
    }
}
