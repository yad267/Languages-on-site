import Foundation

/// Auto folder for user-created lessons (Документы, Путешествия, …).
struct UserLessonCategory: Codable, Identifiable, Hashable {
    var id: String
    var titleRu: String
    var titleEn: String
    var createdAt: Date

    var chip: String { "\(titleRu) · \(titleEn)" }
}

enum UserLessonSourceKind: String, Codable, Hashable {
    case topic
    case text
    case photo
}

/// Offline topic → folder (Gemini may refine later).
enum TopicCategoryClassifier {
    struct Hit: Hashable {
        var id: String
        var titleRu: String
        var titleEn: String
    }

    static let presets: [Hit] = [
        .init(id: "documents", titleRu: "Документы", titleEn: "Documents"),
        .init(id: "travel", titleRu: "Путешествия", titleEn: "Travel"),
        .init(id: "work-site", titleRu: "Работа на объекте", titleEn: "On site"),
        .init(id: "interview", titleRu: "Собеседование", titleEn: "Interview"),
        .init(id: "shopping", titleRu: "Покупки", titleEn: "Shopping"),
        .init(id: "daily", titleRu: "Быт", titleEn: "Daily life"),
        .init(id: "other", titleRu: "Разное", titleEn: "Other"),
    ]

    static func classify(_ raw: String) -> Hit {
        let t = raw.lowercased()

        if matches(t, [
            "документ", "паспорт", "visa", "виза", "intravel", "in travel", "form",
            "анкет", "страховк", "insurance", "permit", "разрешен", "letter",
            "заявлен", "application", "id card", "pps", "gnib", "stamp",
        ]) {
            return presets[0]
        }
        if matches(t, [
            "отпуск", "travel", "flight", "airport", "hotel", "путешест", "билет",
            "поездк", "vacation", "holiday", "туризм", "booking", "airbnb",
        ]) {
            return presets[1]
        }
        if matches(t, [
            "электрик", "объект", "cable", "tray", "трей", "containment", "контентмент",
            "jigsaw", "джигсо", "bandsaw", "бенсоу", "лотк", "кабел", "site",
            "стройк", "монтаж", "foreman", "бригад", "щитов",
        ]) {
            return presets[2]
        }
        if matches(t, [
            "собеседов", "interview", "ищу работ", "job seek", "cv", "резюме", "hire",
        ]) {
            return presets[3]
        }
        if matches(t, [
            "магазин", "купи", "shopping", "store", "цена", "price", "заказ",
        ]) {
            return presets[4]
        }
        if matches(t, [
            "быт", "дом", "dating", "друг", "семь", "врач", "doctor", "everyday",
        ]) {
            return presets[5]
        }
        return presets[6]
    }

    static func category(from hit: Hit, now: Date = Date()) -> UserLessonCategory {
        UserLessonCategory(
            id: hit.id,
            titleRu: hit.titleRu,
            titleEn: hit.titleEn,
            createdAt: now
        )
    }

    private static func matches(_ text: String, _ keys: [String]) -> Bool {
        keys.contains { text.contains($0) }
    }
}
