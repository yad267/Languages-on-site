import Foundation

/// Personal speech lexicon for mixed RU+EN introduction dictation.
/// Output rule: Russian stays Cyrillic; English site slang is written as the learner
/// pronounces it — Cyrillic transliteration only (джигсо, бенсоу, трей…), never Latin,
/// never a Russian translation. SFSpeech hints are Cyrillic-only (Latin hints caused garbage).
enum LearnerSpeechLexicon {
    struct Term: Hashable, Codable, Identifiable {
        var id: String { spoken.lowercased() }
        /// How the learner says it — always Cyrillic (трей, джигсо…).
        var spoken: String
        /// Internal EN gloss for lessons / Gemini (not shown in intro transcript).
        var enCanonical: String
        /// ASR near-misses (Latin + Cyrillic) that must map → `spoken`.
        var asrAliases: [String]
    }

    /// Seed terms from Дима’s tool talk (extend via profile.speechTerms).
    static let seedTerms: [Term] = [
        Term(
            spoken: "трей",
            enCanonical: "tray",
            asrAliases: [
                "трей", "tray", "треи", "трэй", "trai", "trey", "тре", "tree", "trayy",
                "трейд", "trade", "стрей", "стреи", "straight", "cable tray", "cabletray",
            ]
        ),
        Term(
            spoken: "контентмент",
            enCanonical: "containment",
            asrAliases: [
                "контентмент", "containment", "контейнмент", "контеймент", "контент мент",
                "contentment", "content ment", "conteiment", "contain ment",
                "контейн мент", "контейнмент",
            ]
        ),
        Term(
            spoken: "джигсо",
            enCanonical: "jigsaw",
            asrAliases: [
                "джигсо", "jigsaw", "джиг со", "джигсоу", "jig saw", "jigso", "jigsow",
                "джикса", "джигса", "джипсо", "gypsum", "jigsoe",
            ]
        ),
        Term(
            spoken: "бенсоу",
            enCanonical: "bandsaw",
            asrAliases: [
                "бенсоу", "bandsaw", "бендсоу", "band saw", "бен соу", "бэндсоу",
                "бенсо", "benso", "бендоу", "бензо", "бензоу", "bandso", "бандсоу",
            ]
        ),
    ]

    /// Cyrillic-only glue for SFSpeech (no Latin — Latin hints polluted mixed ASR).
    static let cyrillicGlueHints: [String] = [
        "я", "работаю", "кручу", "режу", "металл", "кабель", "лоток", "электрик",
        "на объекте", "в Ирландии", "инструмент", "пила", "трей", "джигсо",
        "бенсоу", "контентмент",
    ]

    /// SFSpeech `contextualStrings` — Cyrillic forms only (Apple cap ~100).
    static func contextualStrings(
        profileTerms: [String] = [],
        tools: [LearnerToolTerm] = []
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func push(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, isMostlyCyrillic(t) else { return }
            let key = t.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            ordered.append(t)
        }

        for term in seedTerms {
            push(term.spoken)
            for a in term.asrAliases where isMostlyCyrillic(a) {
                push(a)
            }
        }
        for raw in profileTerms {
            push(cyrillicForm(raw))
        }
        for tool in tools {
            push(tool.ruLabel)
            push(cyrillicForm(tool.raw))
        }
        for g in cyrillicGlueHints { push(g) }
        return Array(ordered.prefix(100))
    }

    /// Repair ASR → learner Cyrillic slang. Latin EN tokens become transliteration, not translation.
    static func correctASR(
        _ raw: String,
        profileTerms: [String] = []
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        var terms = seedTerms
        for extra in profileTerms {
            let spoken = cyrillicForm(extra)
            guard !spoken.isEmpty else { continue }
            if terms.contains(where: { $0.spoken.compare(spoken, options: .caseInsensitive) == .orderedSame }) {
                continue
            }
            var aliases = [spoken, extra]
            if extra != spoken { aliases.append(extra) }
            terms.append(Term(spoken: spoken, enCanonical: extra, asrAliases: aliases))
        }

        var text = trimmed
        let multi = terms
            .flatMap { term in term.asrAliases.map { ($0, term.spoken) } }
            .filter { $0.0.split(whereSeparator: { $0.isWhitespace }).count >= 2 }
            .sorted { $0.0.count > $1.0.count }
        for (alias, spoken) in multi {
            text = replaceWholePhrase(in: text, alias: alias, with: spoken)
        }

        let parts = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        let mapped = parts.map { token -> String in
            let core = token.trimmingCharacters(in: .punctuationCharacters)
            guard !core.isEmpty else { return token }
            let fixed: String
            if let hit = matchAlias(core, terms: terms) {
                fixed = hit
            } else if looksLatin(core) {
                fixed = transliterateEnglishToCyrillic(core)
            } else {
                fixed = core
            }
            guard fixed != core else { return token }
            return token.replacingOccurrences(of: core, with: fixed)
        }
        return mapped.joined(separator: " ")
    }

    /// Personal dictionary entries (Cyrillic slang) found in text + extras.
    static func extractSpokenTerms(from raw: String, extras: [String] = []) -> [String] {
        let corrected = correctASR(raw, profileTerms: extras)
        let lower = corrected.lowercased()
        var out: [String] = []
        var seen = Set<String>()

        func add(_ s: String) {
            let t = cyrillicForm(s)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { return }
            out.append(t)
        }

        for term in seedTerms {
            let hit = term.asrAliases.contains { lower.contains($0.lowercased()) }
                || lower.contains(term.spoken.lowercased())
            if hit { add(term.spoken) }
        }
        for e in extras { add(e) }

        // Persist newly heard Cyrillic slang tokens (≥4 letters, not stop-words).
        for tok in corrected.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            let core = String(tok).trimmingCharacters(in: .punctuationCharacters).lowercased()
            guard core.count >= 4, isMostlyCyrillic(core), !russianStopWords.contains(core) else { continue }
            if seedTerms.contains(where: { $0.spoken == core }) { add(core) }
        }
        return out
    }

    /// Force a display/storage form: Cyrillic slang, never Latin.
    static func cyrillicForm(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        if let hit = matchAlias(t, terms: seedTerms) { return hit }
        if looksLatin(t) { return transliterateEnglishToCyrillic(t) }
        return t
    }

    static func selfCheckFailures() -> [String] {
        var fails: [String] = []
        let garbled = "I cut metal with jigsaw and bandsaw put cable in tray and install containment"
        let fixed = correctASR(garbled)
        for w in ["джигсо", "бенсоу", "трей", "контентмент"] {
            if !fixed.lowercased().contains(w) {
                fails.append("missing \(w) in «\(fixed)»")
            }
        }
        if fixed.contains(where: { $0.isASCII && $0.isLetter }) {
            // Allow none of the tool English left in Latin.
            for bad in ["jigsaw", "bandsaw", "tray", "containment"] {
                if fixed.lowercased().contains(bad) {
                    fails.append("latin leftover \(bad) in «\(fixed)»")
                }
            }
        }
        let hints = contextualStrings()
        if hints.contains(where: { looksLatin($0) }) {
            fails.append("latin contextual hint: \(hints.filter { looksLatin($0) })")
        }
        if !hints.contains("джигсо") { fails.append("hint missing джигсо") }
        return fails
    }

    // MARK: - Private

    private static let russianStopWords: Set<String> = [
        "этот", "это", "также", "когда", "чтобы", "после", "перед", "очень",
        "работаю", "делаю", "кручу", "режу", "ставлю", "кладу", "металл",
        "кабель", "электрик", "ирландии", "объекте", "инструмент",
    ]

    private static func matchAlias(_ core: String, terms: [Term]) -> String? {
        let key = core.lowercased()
        for term in terms {
            if term.spoken.lowercased() == key { return term.spoken }
            if term.enCanonical.lowercased() == key { return term.spoken }
            if term.asrAliases.contains(where: { $0.lowercased() == key }) {
                return term.spoken
            }
        }
        if key.count >= 4 {
            for term in terms {
                for alias in ([term.spoken, term.enCanonical] + term.asrAliases) {
                    let a = alias.lowercased()
                    guard abs(a.count - key.count) <= 2 else { continue }
                    if editDistance(a, key) <= 2 { return term.spoken }
                }
            }
        }
        return nil
    }

    /// Approximate EN spelling → how a RU speaker would write the sound in Cyrillic.
    static func transliterateEnglishToCyrillic(_ raw: String) -> String {
        let lower = raw.lowercased()
        if let hit = matchAlias(lower, terms: seedTerms) { return hit }

        // Digraph / trigraph pass (order matters).
        var s = lower
        let digraphs: [(String, String)] = [
            ("tion", "шн"), ("sion", "жн"), ("ough", "аф"), ("augh", "о"),
            ("ment", "мент"), ("ture", "чр"), ("tch", "ч"),
            ("sch", "ш"), ("shr", "шр"),
            ("che", "че"), ("chi", "чи"), ("cha", "ча"), ("cho", "чо"), ("chu", "чу"),
            ("sh", "ш"), ("ch", "ч"), ("th", "т"), ("ph", "ф"), ("wh", "в"),
            ("ck", "к"), ("qu", "кв"), ("ng", "нг"),
            ("oo", "у"), ("ee", "и"), ("ea", "и"), ("oa", "о"),
            ("ai", "ей"), ("ay", "ей"), ("oy", "ой"), ("oi", "ой"),
            ("aw", "о"), ("au", "о"), ("ow", "оу"), ("ou", "оу"),
            ("ew", "ю"), ("ie", "и"), ("ye", "е"),
            ("jig", "джиг"), ("band", "бенд"), ("saw", "соу"),
            ("tray", "трей"), ("contain", "контейн"),
        ]
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            var matched = false
            let rest = s[i...]
            for (lat, cyr) in digraphs {
                if rest.lowercased().hasPrefix(lat) {
                    out += cyr
                    i = s.index(i, offsetBy: lat.count)
                    matched = true
                    break
                }
            }
            if matched { continue }
            let ch = s[i]
            out += mapLatinLetter(ch)
            i = s.index(after: i)
        }
        // Soft cleanup: collapse odd doubles.
        while out.contains("аа") { out = out.replacingOccurrences(of: "аа", with: "а") }
        return out.isEmpty ? raw : out
    }

    private static func mapLatinLetter(_ ch: Character) -> String {
        switch ch {
        case "a": return "а"
        case "b": return "б"
        case "c": return "к"
        case "d": return "д"
        case "e": return "е"
        case "f": return "ф"
        case "g": return "г"
        case "h": return "х"
        case "i": return "и"
        case "j": return "дж"
        case "k": return "к"
        case "l": return "л"
        case "m": return "м"
        case "n": return "н"
        case "o": return "о"
        case "p": return "п"
        case "q": return "к"
        case "r": return "р"
        case "s": return "с"
        case "t": return "т"
        case "u": return "у"
        case "v": return "в"
        case "w": return "в"
        case "x": return "кс"
        case "y": return "и"
        case "z": return "з"
        default: return String(ch)
        }
    }

    private static func looksLatin(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }
    }

    private static func isMostlyCyrillic(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let cyr = letters.filter { (0x0400...0x04FF).contains($0.value) }.count
        return Double(cyr) / Double(letters.count) >= 0.6
    }

    private static func replaceWholePhrase(in text: String, alias: String, with spoken: String) -> String {
        let pattern = NSRegularExpression.escapedPattern(for: alias)
        guard let re = try? NSRegularExpression(
            pattern: "(?i)(?<!\\p{L})" + pattern + "(?!\\p{L})",
            options: []
        ) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: spoken)
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let A = Array(a), B = Array(b)
        var prev = Array(0...B.count)
        for i in 1...A.count {
            var cur = [i] + Array(repeating: 0, count: B.count)
            for j in 1...B.count {
                let cost = A[i - 1] == B[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return prev[B.count]
    }
}
