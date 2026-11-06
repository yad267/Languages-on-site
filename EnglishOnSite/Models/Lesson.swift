import Foundation

struct LessonCard: Codable, Identifiable, Hashable {
    var id: String { "\(en)|\(ru)" }
    let en: String
    let ru: String
}

struct Lesson: Codable, Identifiable, Hashable {
    let id: String
    let titleRu: String
    let titleEn: String?
    let tags: [String]
    let sceneRu: String
    let yourRole: String
    let partnerRole: String
    let cards: [LessonCard]
    let lines: [LessonLine]
    let sayToday: [SayTodayPhrase]
    let createdBy: String?
    let topicRaw: String?
    /// Path sort key from pack (optional).
    let order: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case titleRu = "title_ru"
        case titleEn = "title_en"
        case tags
        case sceneRu = "scene_ru"
        case yourRole = "your_role"
        case partnerRole = "partner_role"
        case cards
        case lines
        case dialogue
        case sayToday = "say_today"
        case createdBy = "created_by"
        case topicRaw = "topic_raw"
        case order
    }

    init(
        id: String,
        titleRu: String,
        titleEn: String? = nil,
        tags: [String],
        sceneRu: String,
        yourRole: String,
        partnerRole: String,
        cards: [LessonCard] = [],
        lines: [LessonLine],
        sayToday: [SayTodayPhrase],
        createdBy: String? = nil,
        topicRaw: String? = nil,
        order: Int? = nil
    ) {
        self.id = id
        self.titleRu = titleRu
        self.titleEn = titleEn
        self.tags = tags
        self.sceneRu = sceneRu
        self.yourRole = yourRole
        self.partnerRole = partnerRole
        self.cards = cards
        self.lines = lines
        self.sayToday = sayToday
        self.createdBy = createdBy
        self.topicRaw = topicRaw
        self.order = order
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        titleRu = try c.decode(String.self, forKey: .titleRu)
        titleEn = try c.decodeIfPresent(String.self, forKey: .titleEn)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        sceneRu = try c.decodeIfPresent(String.self, forKey: .sceneRu) ?? ""
        yourRole = try c.decodeIfPresent(String.self, forKey: .yourRole) ?? "electrician"
        partnerRole = try c.decodeIfPresent(String.self, forKey: .partnerRole) ?? "foreman"
        cards = try c.decodeIfPresent([LessonCard].self, forKey: .cards) ?? []
        if let lines = try c.decodeIfPresent([LessonLine].self, forKey: .lines) {
            self.lines = lines
        } else if let dialogue = try c.decodeIfPresent([LessonLine].self, forKey: .dialogue) {
            self.lines = dialogue
        } else {
            self.lines = []
        }
        sayToday = try c.decodeIfPresent([SayTodayPhrase].self, forKey: .sayToday) ?? []
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        topicRaw = try c.decodeIfPresent(String.self, forKey: .topicRaw)
        order = try c.decodeIfPresent(Int.self, forKey: .order)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(titleRu, forKey: .titleRu)
        try c.encodeIfPresent(titleEn, forKey: .titleEn)
        try c.encode(tags, forKey: .tags)
        try c.encode(sceneRu, forKey: .sceneRu)
        try c.encode(yourRole, forKey: .yourRole)
        try c.encode(partnerRole, forKey: .partnerRole)
        if !cards.isEmpty {
            try c.encode(cards, forKey: .cards)
        }
        try c.encode(lines, forKey: .lines)
        try c.encode(sayToday, forKey: .sayToday)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encodeIfPresent(topicRaw, forKey: .topicRaw)
        try c.encodeIfPresent(order, forKey: .order)
    }

    var isUserLesson: Bool {
        if let createdBy, createdBy.hasPrefix("user") { return true }
        return id.hasPrefix("user-")
    }

    var isSiteInduction: Bool {
        tags.contains("induction") || id.hasPrefix("lesson_0_")
    }

    var displayTitle: String {
        if let titleEn, !titleEn.isEmpty {
            return "\(titleRu) · \(titleEn)"
        }
        return titleRu
    }

    func roleLabel(for role: String) -> String {
        if role == yourRole { return "Монтажник" }
        if role == partnerRole { return "Бригадир" }
        switch role {
        case "electrician", "worker": return "Монтажник"
        case "foreman", "supervisor": return "Бригадир"
        case "client": return "Клиент"
        case "colleague": return "Коллега"
        default: return role.capitalized
        }
    }

    /// Supervisor / partner side of the dialogue (left bubble).
    func isSupervisorRole(_ role: String) -> Bool {
        if role == partnerRole { return true }
        switch role {
        case "foreman", "supervisor", "client": return true
        default: return false
        }
    }

    /// Worker / learner side (right bubble).
    func isWorkerRole(_ role: String) -> Bool {
        if role == yourRole { return true }
        switch role {
        case "electrician", "worker", "colleague": return true
        default: return !isSupervisorRole(role)
        }
    }

    /// EN ElevenLabs voice for a dialogue line (never RU clone).
    func enVoiceId(for role: String, settings: AppSettings) -> String {
        if isSupervisorRole(role) {
            return settings.resolvedVoiceIdEnSupervisor
        }
        return ElevenLabsConfig.voiceIdEnWorker
    }

    /// Validate after Gemini / disk load. Needs lines≥4, say_today≥1, non-empty en/ru.
    func validated() -> Lesson? {
        guard lines.count >= 4, sayToday.count >= 1 else { return nil }
        guard lines.allSatisfy({
            !$0.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        guard sayToday.allSatisfy({
            !$0.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        return self
    }
}

struct LessonLine: Codable, Identifiable, Hashable {
    var id: String { "\(en)|\(ru)|\(role)" }
    let en: String
    let ru: String
    let role: String
    let tipRu: String?
    let practice: Bool?

    enum CodingKeys: String, CodingKey {
        case en, ru, role
        case tipRu = "tip_ru"
        case practice
    }

    init(en: String, ru: String, role: String, tipRu: String? = nil, practice: Bool? = nil) {
        self.en = en
        self.ru = ru
        self.role = role
        self.tipRu = tipRu
        self.practice = practice
    }

    var isPractice: Bool {
        practice == true || role == "electrician"
    }
}

struct SayTodayPhrase: Codable, Identifiable, Hashable {
    var id: String { "\(en)|\(ru)" }
    let en: String
    let ru: String
}

enum LessonLoader {
    /// Prefer bundled lessons_pack.json; fallback to legacy per-file JSON.
    static func loadBundle() -> [Lesson] {
        if let url = Bundle.main.url(forResource: "lessons_pack", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let pack = try? JSONDecoder().decode(LessonPack.self, from: data) {
            return pack.lessons
                .compactMap { $0.validated() }
                .sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }
        }
        let names = [
            "lesson-0-1-safe-pass",
            "lesson-0-2-induction",
            "lesson-0-3-ppe",
        ]
        return names.compactMap { load(named: $0) }
    }

    /// Backward-compatible alias.
    static func loadAll() -> [Lesson] { loadBundle() }

    static func load(named name: String) -> Lesson? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Lesson.self, from: data)
        } catch {
            print("LessonLoader error \(name): \(error)")
            return nil
        }
    }
}

enum LessonTopicParser {
    /// Pull topic from «урок про …», «сделай урок: …», or return trimmed text if no command prefix.
    static func extractTopic(from text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?i)^\s*(?:сделай\s+)?(?:новый\s+)?урок\s*(?:про|по|:)?\s*"#,
            #"(?i)^\s*новый\s+урок\s*(?:про|по|:)?\s*"#,
        ]
        for p in patterns {
            if let r = try? NSRegularExpression(pattern: p) {
                t = r.stringByReplacingMatches(
                    in: t,
                    range: NSRange(t.startIndex..., in: t),
                    withTemplate: ""
                )
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func slug(from topic: String) -> String {
        let lowered = topic.lowercased()
        let allowed = lowered.unicodeScalars.map { s -> Character in
            if CharacterSet.alphanumerics.contains(s) { return Character(s) }
            return "-"
        }
        var slug = String(allowed)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 32 { slug = String(slug.prefix(32)) }
        return slug.isEmpty ? "topic" : slug
    }

    static func makeUserLessonId(topic: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return "user-\(f.string(from: date))-\(slug(from: topic))"
    }
}
