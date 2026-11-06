import Foundation

struct VoiceCommands: Codable, Equatable {
    var stop: [String]
    var pause: [String]
    var resume: [String]
    var repeatLast: [String]
    var translate: [String]
    var remember: [String]
    var newLesson: [String]

    static let `default` = VoiceCommands(
        stop: ["стоп", "стой"],
        pause: ["пауза"],
        resume: ["дальше", "продолжай", "продолжить"],
        repeatLast: ["повтори", "ещё раз", "еще раз"],
        translate: ["перевод", "переведи"],
        remember: ["запомни", "запомнить"],
        newLesson: ["урок", "новый урок", "сделай урок"]
    )

    init(
        stop: [String],
        pause: [String],
        resume: [String],
        repeatLast: [String],
        translate: [String],
        remember: [String],
        newLesson: [String] = VoiceCommands.default.newLesson
    ) {
        self.stop = stop
        self.pause = pause
        self.resume = resume
        self.repeatLast = repeatLast
        self.translate = translate
        self.remember = remember
        self.newLesson = newLesson
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stop = try c.decodeIfPresent([String].self, forKey: .stop) ?? Self.default.stop
        pause = try c.decodeIfPresent([String].self, forKey: .pause) ?? Self.default.pause
        resume = try c.decodeIfPresent([String].self, forKey: .resume) ?? Self.default.resume
        repeatLast = try c.decodeIfPresent([String].self, forKey: .repeatLast) ?? Self.default.repeatLast
        translate = try c.decodeIfPresent([String].self, forKey: .translate) ?? Self.default.translate
        remember = try c.decodeIfPresent([String].self, forKey: .remember) ?? Self.default.remember
        newLesson = try c.decodeIfPresent([String].self, forKey: .newLesson) ?? Self.default.newLesson
    }

    var allKeywords: [String] {
        stop + pause + resume + repeatLast + translate + remember + newLesson
    }

    func match(in text: String) -> VoiceCommandAction? {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Longer / more specific first
        for word in newLesson.sorted(by: { $0.count > $1.count }) where normalized.contains(word) {
            return .newLesson
        }
        for word in remember where normalized.contains(word) { return .remember }
        for word in translate where normalized.contains(word) { return .translate }
        for word in stop where normalized.contains(word) { return .stop }
        for word in pause where normalized.contains(word) { return .pause }
        for word in resume where normalized.contains(word) { return .resume }
        for word in repeatLast where normalized.contains(word) { return .repeatLast }
        return nil
    }
}

enum VoiceCommandAction: String {
    case stop
    case pause
    case resume
    case repeatLast
    case translate
    case remember
    case newLesson
}
