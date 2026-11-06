import Foundation

enum TutorContentMode: String, CaseIterable, Identifiable {
    case site
    case general

    var id: String { rawValue }

    var titleRU: String {
        switch self {
        case .site: return "На объекте"
        case .general: return "Обычный EN"
        }
    }
}

struct VerbEntry: Codable, Identifiable, Hashable {
    var id: String { lemma }
    let lemma: String
    let base: String
    let past: String
    let pp: String
    let third: String
    let type: String
    let ru: String

    enum CodingKeys: String, CodingKey {
        case lemma, base, past, pp, third, type, ru
    }
}

struct PhrasalEntry: Codable, Identifiable, Hashable {
    var id: String { en }
    let en: String
    let ru: String
    let exampleEn: String
    let exampleRu: String
    let root: String
    let tier: Int

    enum CodingKeys: String, CodingKey {
        case en, ru, root, tier
        case exampleEn = "example_en"
        case exampleRu = "example_ru"
    }

    init(en: String, ru: String, exampleEn: String, exampleRu: String = "", root: String? = nil, tier: Int = 1) {
        self.en = en
        self.ru = ru
        self.exampleEn = exampleEn
        self.exampleRu = exampleRu
        let inferred = root?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.root = (inferred?.isEmpty == false) ? inferred! : (en.split(separator: " ").first.map(String.init) ?? en)
        self.tier = tier
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        en = try c.decode(String.self, forKey: .en)
        ru = try c.decode(String.self, forKey: .ru)
        exampleEn = try c.decodeIfPresent(String.self, forKey: .exampleEn) ?? ""
        exampleRu = try c.decodeIfPresent(String.self, forKey: .exampleRu) ?? ""
        let rawRoot = try c.decodeIfPresent(String.self, forKey: .root)
        root = (rawRoot?.isEmpty == false) ? rawRoot! : (en.split(separator: " ").first.map(String.init) ?? en)
        tier = try c.decodeIfPresent(Int.self, forKey: .tier) ?? 1
    }
}

struct OppositeEntry: Codable, Identifiable, Hashable {
    var id: String { "\(a)|\(b)" }
    let a: String
    let b: String
    let ru: String
    /// 1 = core (pairs/drill first); 2+ = later.
    let tier: Int

    enum CodingKeys: String, CodingKey { case a, b, ru, tier }

    init(a: String, b: String, ru: String, tier: Int = 1) {
        self.a = a
        self.b = b
        self.ru = ru
        self.tier = tier
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        a = try c.decode(String.self, forKey: .a)
        b = try c.decode(String.self, forKey: .b)
        ru = try c.decode(String.self, forKey: .ru)
        tier = try c.decodeIfPresent(Int.self, forKey: .tier) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(a, forKey: .a)
        try c.encode(b, forKey: .b)
        try c.encode(ru, forKey: .ru)
        try c.encode(tier, forKey: .tier)
    }
}

/// Bundle banks + user-added verbs. Mode `.site` | `.general` switches active banks.
@MainActor
enum TutorBankStore {
    private static let extraVerbsKey = "tutorExtraVerbs_v1"
    private static let extraVerbsGeneralKey = "tutorExtraVerbs_general_v1"

    private(set) static var contentMode: TutorContentMode = .site

    private(set) static var verbs: [VerbEntry] = []
    private(set) static var phrasals: [PhrasalEntry] = []
    private(set) static var opposites: [OppositeEntry] = []

    static func setMode(_ mode: TutorContentMode) {
        if mode == contentMode {
            ensureLoaded()
            return
        }
        contentMode = mode
        reload()
    }

    static func reload() {
        switch contentMode {
        case .site:
            verbs = loadJSON("verbs_bank_v1", key: "verbs") + loadExtraVerbs(key: extraVerbsKey)
            phrasals = loadJSON("phrasals_bank_v1", key: "phrasals")
            opposites = loadJSON("opposites_bank_v1", key: "opposites")
        case .general:
            verbs = loadJSON("verbs_general_v1", key: "verbs") + loadExtraVerbs(key: extraVerbsGeneralKey)
            phrasals = loadJSON("phrasals_general_v1", key: "phrasals")
            opposites = loadJSON("opposites_general_v1", key: "opposites")
        }
        var seen = Set<String>()
        verbs = verbs.filter { v in
            let k = v.lemma.lowercased()
            guard !seen.contains(k) else { return false }
            seen.insert(k)
            return true
        }
        phrasals = Self.enrichPhrasalExamples(phrasals)
    }

    static func ensureLoaded() {
        if verbs.isEmpty && phrasals.isEmpty { reload() }
    }

    /// B10: core-first for drills / pairs (tier ≤ 1).
    static var corePhrasals: [PhrasalEntry] {
        ensureLoaded()
        let core = phrasals.filter { $0.tier <= 1 }
        return core.isEmpty ? phrasals : core
    }

    static var coreOpposites: [OppositeEntry] {
        ensureLoaded()
        let core = opposites.filter { $0.tier <= 1 }
        return core.isEmpty ? opposites : core
    }

    static func addVerb(lemma raw: String, ru: String = "") -> Bool {
        let lemma = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lemma.count >= 2, lemma.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" }) else { return false }
        ensureLoaded()
        if verbs.contains(where: { $0.lemma.lowercased() == lemma }) { return false }
        let third: String
        if lemma.hasSuffix("y"), let c = lemma.dropLast().last, !"aeiou".contains(c) {
            third = String(lemma.dropLast()) + "ies"
        } else if lemma.hasSuffix("s") || lemma.hasSuffix("x") || lemma.hasSuffix("ch") || lemma.hasSuffix("sh") {
            third = lemma + "es"
        } else {
            third = lemma + "s"
        }
        let past: String
        if lemma.hasSuffix("e") { past = lemma + "d" }
        else if lemma.hasSuffix("y"), let c = lemma.dropLast().last, !"aeiou".contains(c) {
            past = String(lemma.dropLast()) + "ied"
        } else {
            past = lemma + "ed"
        }
        let entry = VerbEntry(
            lemma: lemma,
            base: lemma,
            past: past,
            pp: past,
            third: third,
            type: "do",
            ru: ru.isEmpty ? lemma : ru
        )
        let key = contentMode == .site ? extraVerbsKey : extraVerbsGeneralKey
        var extras = loadExtraVerbs(key: key)
        extras.append(entry)
        if let data = try? JSONEncoder().encode(extras) {
            UserDefaults.standard.set(data, forKey: key)
        }
        reload()
        return true
    }

    static func verb(named lemma: String) -> VerbEntry? {
        ensureLoaded()
        return verbs.first { $0.lemma.lowercased() == lemma.lowercased() }
    }

    /// Filter phrasals by root / leading verb / contains word (e.g. «take»).
    static func phrasals(matching query: String) -> [PhrasalEntry] {
        ensureLoaded()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return phrasals.filter { $0.tier <= 1 }.isEmpty ? phrasals : phrasals.filter { $0.tier <= 1 }
        }
        return phrasals.filter { p in
            let en = p.en.lowercased()
            let root = p.root.lowercased()
            if root == q { return true }
            if en.hasPrefix(q + " ") || en == q { return true }
            let tokens = en.split(separator: " ").map(String.init)
            return tokens.contains(q)
        }
    }

    // MARK: - Gloss RU (pairs tap)

    private static let glossCacheKey = "tutorPairsGlossCache_v1"

    /// Synchronous gloss from banks + disk cache. Empty → caller may fetch Gemini.
    static func glossRU(forEN raw: String) -> String? {
        ensureLoaded()
        let en = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !en.isEmpty else { return nil }
        let key = en.lowercased()

        if let p = phrasals.first(where: { $0.en.lowercased() == key }), !p.ru.isEmpty {
            return p.ru
        }
        if let v = verbs.first(where: { $0.lemma.lowercased() == key }), !v.ru.isEmpty {
            return v.ru
        }
        for o in opposites {
            let parts = splitOppositeRU(o.ru)
            if o.a.lowercased() == key, let ru = parts.left, !ru.isEmpty { return ru }
            if o.b.lowercased() == key, let ru = parts.right, !ru.isEmpty { return ru }
            if o.a.lowercased() == key { return parts.left ?? o.ru }
            if o.b.lowercased() == key { return parts.right ?? o.ru }
        }
        if let cached = loadGlossCache()[key], !cached.isEmpty {
            return cached
        }
        return nil
    }

    static func cacheGloss(en: String, ru: String) {
        let e = en.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let r = ru.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty, !r.isEmpty else { return }
        var map = loadGlossCache()
        map[e] = r
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: glossCacheKey)
        }
    }

    static func splitOppositeRU(_ ru: String) -> (left: String?, right: String?) {
        let seps = ["↔", "<->", "→", "—", "–", "/"]
        for sep in seps {
            if let r = ru.range(of: sep) {
                let l = String(ru[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rr = String(ru[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (l.isEmpty ? nil : l, rr.isEmpty ? nil : rr)
            }
        }
        let t = ru.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.isEmpty ? nil : t, nil)
    }

    private static func loadGlossCache() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: glossCacheKey),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    private static func loadExtraVerbs(key: String) -> [VerbEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([VerbEntry].self, from: data) else { return [] }
        return arr
    }

    private static func loadJSON<T: Decodable>(_ name: String, key: String) -> [T] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj[key],
              let raw = try? JSONSerialization.data(withJSONObject: arr),
              let decoded = try? JSONDecoder().decode([T].self, from: raw) else {
            print("[tutor-bank] miss \(name).json /\(key)")
            return []
        }
        return decoded
    }

    /// B11: fill missing A1–A2 examples for known core phrasals (JSON may still lack example_ru).
    private static func enrichPhrasalExamples(_ list: [PhrasalEntry]) -> [PhrasalEntry] {
        let presets: [String: (en: String, ru: String, tier: Int)] = [
            "hand over": ("Please hand over the keys.", "Передай ключи, пожалуйста.", 1),
            "sign in": ("I need to sign in at the gate.", "Мне нужно отметиться на воротах.", 1),
            "sign out": ("Don't forget to sign out.", "Не забудь выйти с объекта.", 1),
            "turn on": ("Can you turn on the light?", "Можешь включить свет?", 1),
            "turn off": ("Please turn off the power.", "Пожалуйста, выключи питание.", 1),
            "switch on": ("Switch on the panel.", "Включи щит.", 1),
            "switch off": ("Switch off the isolator.", "Обесточь изолятор.", 1),
            "put on": ("Put on your hard hat.", "Надень каску.", 1),
            "take off": ("Take off your gloves first.", "Сначала сними перчатки.", 1),
            "put back": ("Put the tools back.", "Положи инструменты обратно.", 1),
            "pick up": ("Can you pick up the cable?", "Можешь поднять кабель?", 1),
            "clean up": ("Please clean up after work.", "Пожалуйста, убери за собой после работы.", 1),
            "clear away": ("Clear away the tools.", "Убери инструменты с прохода.", 1),
            "shut down": ("Shut down the system.", "Выключи систему.", 1),
            "power down": ("Power down before you start.", "Обесточь перед началом.", 1),
            "look for": ("I'm looking for the foreman.", "Я ищу прораба.", 1),
            "fill in": ("Please fill in the form.", "Заполни форму, пожалуйста.", 1),
            "lay out": ("Lay out the drawings here.", "Разложи чертежи здесь.", 1),
            "mark out": ("Mark out the holes first.", "Сначала разметь отверстия.", 1),
            "take down": ("Take down that sign.", "Сними ту табличку.", 1),
            "put away": ("Put away the drill.", "Убери дрель.", 1),
            "come in": ("Come in through the gate.", "Заходи через ворота.", 1),
            "go back": ("Go back to the van.", "Вернись к фургону.", 1),
            "get in": ("Get in the van.", "Садись в фургон.", 1),
            "get out": ("Get out of the way.", "Отойди с дороги.", 1),
            "find out": ("I need to find out the time.", "Мне нужно узнать время.", 1),
            "give back": ("Give back the pass.", "Верни пропуск.", 1),
            "hold on": ("Hold on a second.", "Подожди секунду.", 1),
            "carry on": ("Carry on with the job.", "Продолжай работу.", 1),
            "check in": ("Check in at reception.", "Отметься на ресепшене.", 1),
        ]
        return list.map { p in
            let key = p.en.lowercased()
            guard let pre = presets[key] else {
                // Non-preset: keep, but bump vague cable-tray examples off core feel via tier if junk.
                if p.exampleEn.localizedCaseInsensitiveContains("cable tray"), p.tier <= 1 {
                    return PhrasalEntry(
                        en: p.en, ru: p.ru,
                        exampleEn: p.exampleEn, exampleRu: p.exampleRu,
                        root: p.root, tier: 2
                    )
                }
                return p
            }
            let enEx = p.exampleEn.trimmingCharacters(in: .whitespacesAndNewlines)
            let ruEx = p.exampleRu.trimmingCharacters(in: .whitespacesAndNewlines)
            let useEn = (enEx.isEmpty || enEx.localizedCaseInsensitiveContains("cable tray")) ? pre.en : enEx
            let useRu = ruEx.isEmpty ? pre.ru : ruEx
            return PhrasalEntry(
                en: p.en, ru: p.ru,
                exampleEn: useEn, exampleRu: useRu,
                root: p.root, tier: min(p.tier, pre.tier)
            )
        }
    }
}
