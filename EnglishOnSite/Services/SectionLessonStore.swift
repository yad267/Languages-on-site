import Foundation

struct LessonSectionInfo: Identifiable, Hashable, Codable {
    let id: String
    let titleRu: String
    let titleEn: String
    let track: String
    let lessonIds: [String]
    let lessonCount: Int

    enum CodingKeys: String, CodingKey {
        case id, track
        case titleRu = "title_ru"
        case titleEn = "title_en"
        case lessonIds = "lesson_ids"
        case lessonCount = "lesson_count"
    }
}

/// Bundled Onsite / Regular subsection lessons (10–15 each).
enum SectionLessonStore {
    private struct Pack: Codable {
        let version: Int?
        let track: String?
        let sections: [LessonSectionInfo]
        let lessons: [Lesson]
    }

    private static var onsitePack: Pack?
    private static var regularPack: Pack?

    private static func load(resource: String) -> Pack? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let pack = try? JSONDecoder().decode(Pack.self, from: data) else {
            return nil
        }
        return pack
    }

    private static func onsite() -> Pack {
        if let onsitePack { return onsitePack }
        let p = load(resource: "lessons_onsite_sections_v1") ?? Pack(version: 1, track: "onsite", sections: [], lessons: [])
        onsitePack = p
        return p
    }

    private static func regular() -> Pack {
        if let regularPack { return regularPack }
        let p = load(resource: "lessons_regular_sections_v1") ?? Pack(version: 1, track: "regular", sections: [], lessons: [])
        regularPack = p
        return p
    }

    static func sections(track: AppLearningMode) -> [LessonSectionInfo] {
        switch track {
        case .onSite: return onsite().sections
        case .regular: return regular().sections
        }
    }

    static func lessons(sectionId: String, track: AppLearningMode) -> [Lesson] {
        let pack = track == .onSite ? onsite() : regular()
        let ids = Set(pack.sections.first(where: { $0.id == sectionId })?.lessonIds ?? [])
        return pack.lessons
            .filter { ids.contains($0.id) }
            .sorted { ($0.order ?? 0) < ($1.order ?? 0) }
    }

    static func lesson(id: String) -> Lesson? {
        onsite().lessons.first(where: { $0.id == id })
            ?? regular().lessons.first(where: { $0.id == id })
    }
}
