import Foundation
import Observation

/// Single source for Path: bundled pack → disk cache → Drive update (LessonsConfig URL).
@Observable
@MainActor
final class LessonStore {
    static let shared = LessonStore()

    private(set) var lessons: [Lesson] = []
    private(set) var contentVersion: Int = 0
    private(set) var sourceLabel: String = "bundled"
    private(set) var lastStatusRU: String = ""
    private(set) var isChecking = false

    private var checkedThisSession = false

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("LessonPack", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("lessons_pack.json")
    }

    private var versionURL: URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("content_version.txt")
    }

    init() {
        reloadLocal()
    }

    func reloadLocal() {
        let cached = loadPack(from: cacheURL)
        let bundled = loadBundled()
        if let cached, let bundled {
            if cached.contentVersion >= bundled.contentVersion {
                apply(cached, source: "cache")
            } else {
                apply(bundled, source: "bundled")
            }
            return
        }
        if let cached {
            apply(cached, source: "cache")
            return
        }
        if let bundled {
            apply(bundled, source: "bundled")
            return
        }
        // Legacy per-file fallback
        let legacy = LessonLoader.loadBundle()
        lessons = legacy
        contentVersion = 0
        sourceLabel = "legacy"
        lastStatusRU = legacy.isEmpty ? "Нет уроков" : "Legacy JSON (\(legacy.count))"
    }

    /// Quiet once-per-session check (built-in Drive URL).
    func checkForUpdatesIfNeeded(settings: AppSettings) async {
        guard !checkedThisSession else { return }
        checkedThisSession = true
        guard LessonsConfig.isPackURLConfigured else { return }
        await checkForUpdates(settings: settings, quiet: true)
    }

    @discardableResult
    func checkForUpdates(settings: AppSettings, quiet: Bool = false) async -> String {
        guard LessonsConfig.isPackURLConfigured else {
            let msg = "Drive URL ещё не задан (REPLACE_DRIVE_FILE_ID). Локальный pack v\(contentVersion)."
            if !quiet { lastStatusRU = msg }
            return msg
        }
        guard let url = URL(string: LessonsConfig.lessonsPackURL) else {
            let msg = "Неверный URL пакета"
            lastStatusRU = msg
            return msg
        }

        isChecking = true
        defer { isChecking = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let msg = "Скачивание: HTTP \(http.statusCode) — оставлен локальный pack"
                lastStatusRU = msg
                return msg
            }
            // Drive sometimes returns HTML interstitial for large files
            if let head = String(data: data.prefix(80), encoding: .utf8),
               head.lowercased().contains("<!doctype html") || head.lowercased().contains("<html") {
                let msg = "Drive вернул HTML (проверь доступ «по ссылке») — локальный pack"
                lastStatusRU = msg
                return msg
            }
            let pack = try JSONDecoder().decode(LessonPack.self, from: data)
            guard pack.lessons.contains(where: { $0.validated() != nil }) else {
                let msg = "Пакет пустой или битый — локальный pack"
                lastStatusRU = msg
                return msg
            }
            if pack.contentVersion <= contentVersion {
                let msg = "Уроки актуальны (v\(contentVersion))"
                lastStatusRU = msg
                return msg
            }
            try data.write(to: cacheURL, options: .atomic)
            try? "\(pack.contentVersion)".write(to: versionURL, atomically: true, encoding: .utf8)
            // completedLessonIds intentionally untouched across pack versions.
            apply(pack, source: "cache")
            EosSyncService.postLessonPackIfConfigured(
                settings: settings,
                contentVersion: pack.contentVersion,
                packJSON: data
            )
            let msg = "Уроки обновлены (v\(pack.contentVersion))"
            lastStatusRU = msg
            print("[lessons] updated v\(pack.contentVersion) count=\(lessons.count)")
            return msg
        } catch {
            let msg = "Нет сети / пакет — локальный v\(contentVersion)"
            lastStatusRU = msg
            print("[lessons] update fail \(error.localizedDescription)")
            return msg
        }
    }

    var firstIncomplete: Lesson? {
        lessons.first { !LessonProgressStore.isCompleted($0.id) } ?? lessons.first
    }

    private func apply(_ pack: LessonPack, source: String) {
        let sorted = pack.lessons
            .compactMap { $0.validated() }
            .sorted { a, b in
                let oa = a.order ?? Int.max
                let ob = b.order ?? Int.max
                if oa != ob { return oa < ob }
                return a.id < b.id
            }
        lessons = sorted
        contentVersion = pack.contentVersion
        sourceLabel = source
        lastStatusRU = "v\(pack.contentVersion) · \(sorted.count) уроков · \(source)"
    }

    private func loadBundled() -> LessonPack? {
        guard let url = Bundle.main.url(forResource: "lessons_pack", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LessonPack.self, from: data)
    }

    private func loadPack(from url: URL) -> LessonPack? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LessonPack.self, from: data)
    }
}
