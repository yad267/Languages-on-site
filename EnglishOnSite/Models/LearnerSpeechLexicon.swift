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

    /// Spoken forms found in text (compat helper).
    static func extractSpokenTerms(from raw: String, extras: [String] = []) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for e in harvestEntries(from: raw, knownSpoken: [], source: .manual) {
            if seen.insert(e.spoken.lowercased()).inserted { out.append(e.spoken) }
        }
        for x in extras {
            let t = cyrillicForm(x)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
        }
        return out
    }

    /// New slang candidates not yet in `knownSpoken` (seed hits + Latin→Cyrillic + slang-like tokens).
    static func harvestEntries(
        from raw: String,
        knownSpoken: Set<String>,
        source: SpeechTermSource
    ) -> [LearnerSpeechTermEntry] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let rawTokens = trimmed
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }

        let corrected = correctASR(trimmed, profileTerms: Array(knownSpoken))
        var out: [LearnerSpeechTermEntry] = []
        var seen = Set(knownSpoken.map { $0.lowercased() })

        func consider(_ spokenRaw: String, enHint: String?, aliases: [String]) {
            let spoken = cyrillicForm(spokenRaw)
            guard spoken.count >= 3, isMostlyCyrillic(spoken) else { return }
            let key = spoken.lowercased()
            guard !russianStopWords.contains(key), seen.insert(key).inserted else { return }
            let slangy = looksLikeLearnerSlang(spoken) || seedTerms.contains { $0.spoken == spoken }
            let fromLatin = aliases.contains { looksLatin($0) } || (enHint != nil)
            guard slangy || fromLatin else { return }
            var entry = LearnerSpeechTermEntry(
                spoken: spoken,
                enHint: enHint,
                aliases: aliases.filter { !$0.isEmpty },
                source: source
            )
            if let seed = seedTerms.first(where: { $0.spoken == spoken }) {
                entry.enHint = seed.enCanonical
                entry.aliases = Array(Set(entry.aliases + seed.asrAliases))
            }
            out.append(entry)
        }

        for tok in rawTokens where looksLatin(tok) {
            let cyr = transliterateEnglishToCyrillic(tok)
            consider(cyr, enHint: tok.lowercased(), aliases: [tok, cyr])
        }

        for tok in corrected.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            let core = String(tok).trimmingCharacters(in: .punctuationCharacters)
            guard !core.isEmpty else { continue }
            if let seed = seedTerms.first(where: {
                $0.spoken.compare(core, options: .caseInsensitive) == .orderedSame
                    || $0.asrAliases.contains { $0.compare(core, options: .caseInsensitive) == .orderedSame }
            }) {
                consider(seed.spoken, enHint: seed.enCanonical, aliases: seed.asrAliases)
            } else {
                consider(core, enHint: nil, aliases: [core])
            }
        }
        return out
    }

    private static func looksLikeLearnerSlang(_ spoken: String) -> Bool {
        let t = spoken.lowercased()
        if seedTerms.contains(where: { $0.spoken == t }) { return true }
        let markers = ["соу", "джиг", "трей", "мент", "флюкс", "контейн", "бенд", "кейбл", "лотк"]
        if markers.contains(where: { t.contains($0) }) { return true }
        if t.count >= 4, t.hasSuffix("соу") || t.hasSuffix("ей") || t.hasSuffix("мент") { return true }
        return false
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
