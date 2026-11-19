import Foundation

/// Personal / site speech lexicon for mixed RU+EN introduction dictation.
/// SFSpeech is single-locale; we bias it with `contextualStrings` and repair near-misses
/// so learner slang (трей, джигсо, бенсоу, контентмент) is not “fixed” into garbage.
enum LearnerSpeechLexicon {
    struct Term: Hashable, Codable, Identifiable {
        var id: String { enCanonical.lowercased() }
        /// Preferred display form as the learner says it (often phonetic RU).
        var spoken: String
        /// Ireland/UK site English.
        var enCanonical: String
        /// ASR near-misses (Cyrillic + Latin) that must map back to `spoken`.
        var asrAliases: [String]
    }

    /// Seed terms from Дима’s tool talk (extend via profile.speechTerms).
    static let seedTerms: [Term] = [
        Term(
            spoken: "трей",
            enCanonical: "tray",
            asrAliases: [
                "трей", "tray", "треи", "трэй", "trai", "trey", "тре", "tree", "trayy",
                "трейд", "trade", "стрей", "стреи", "straight", "cable tray",
            ]
        ),
        Term(
            spoken: "контентмент",
            enCanonical: "containment",
            asrAliases: [
                "контентмент", "containment", "контейнмент", "контеймент", "контент мент",
                "contentment", "content ment", "контент", "conteiment", "contain ment",
                "контейн мент", "контейнмент",
            ]
        ),
        Term(
            spoken: "джигсо",
            enCanonical: "jigsaw",
            asrAliases: [
                "джигсо", "jigsaw", "джиг со", "джигсоу", "jig saw", "jigso", "jigsow",
                "джикса", "джигса", "джипсо", "gypsum", "jigsoe", "джигсоу пила",
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

    /// Extra short hints for free mixed dictation (RU matrix + EN site words).
    static let bilingualGlueHints: [String] = [
        "я", "работаю", "кручу", "режу", "метал", "кабель", "лоток", "электрик",
        "на объекте", "в Ирландии", "инструмент", "пила", "tray", "containment",
        "jigsaw", "bandsaw", "cable tray", "metal",
    ]

    /// Build SFSpeech `contextualStrings` (short forms first; Apple cap ~100).
    static func contextualStrings(
        profileTerms: [String] = [],
        tools: [LearnerToolTerm] = []
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func push(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            let key = t.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            ordered.append(t)
        }

        for term in seedTerms {
            push(term.spoken)
            push(term.enCanonical)
            for a in term.asrAliases.prefix(6) { push(a) }
        }
        for raw in profileTerms {
            push(raw)
        }
        for tool in tools {
            push(tool.raw)
            push(tool.enCanonical)
            for part in tool.enCanonical.split(separator: " ") {
                push(String(part))
            }
        }
        for g in bilingualGlueHints { push(g) }
        return Array(ordered.prefix(100))
    }

    /// Map ASR near-misses onto the learner’s spoken forms (never invent unrelated words).
    static func correctASR(
        _ raw: String,
        profileTerms: [String] = []
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        var terms = seedTerms
        for extra in profileTerms {
            let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !e.isEmpty else { continue }
            if terms.contains(where: { $0.spoken.compare(e, options: .caseInsensitive) == .orderedSame }) {
                continue
            }
            terms.append(Term(spoken: e, enCanonical: e, asrAliases: [e]))
        }

        // Multi-word aliases first (longest first).
        var text = trimmed
        let multi = terms
            .flatMap { term in term.asrAliases.map { ($0, term.spoken) } }
            .filter { $0.0.split(whereSeparator: { $0.isWhitespace }).count >= 2 }
            .sorted { $0.0.count > $1.0.count }
        for (alias, spoken) in multi {
            text = replaceWholePhrase(in: text, alias: alias, with: spoken)
        }

        // Token pass for single-word slang (keep surrounding punctuation).
        let parts = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        let mapped = parts.map { token -> String in
            let core = token.trimmingCharacters(in: .punctuationCharacters)
            guard !core.isEmpty else { return token }
            let fixed = matchAlias(core, terms: terms) ?? core
            guard fixed != core else { return token }
            return token.replacingOccurrences(of: core, with: fixed)
        }
        return mapped.joined(separator: " ")
    }

    /// Pull personal speech terms out of an introduction (seed hits + profile extras).
    static func extractSpokenTerms(from raw: String, extras: [String] = []) -> [String] {
        let corrected = correctASR(raw, profileTerms: extras)
        let lower = corrected.lowercased()
        var out: [String] = []
        var seen = Set<String>()
        for term in seedTerms {
            let hit = term.asrAliases.contains { lower.contains($0.lowercased()) }
                || lower.contains(term.spoken.lowercased())
                || lower.contains(term.enCanonical.lowercased())
            if hit, seen.insert(term.spoken.lowercased()).inserted {
                out.append(term.spoken)
            }
        }
        for e in extras {
            let t = e.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            if lower.contains(t.lowercased()) { out.append(t) }
        }
        return out
    }

    static func selfCheckFailures() -> [String] {
        var fails: [String] = []
        // Simulate typical SFSpeech garbage on mixed RU/EN tool talk.
        let garbled = "я режу металл джипсо и бензоу кладу кабель в стреи и ставлю контент мент"
        let fixed = correctASR(garbled)
        let want = ["джигсо", "бенсоу", "трей", "контентмент"]
        for w in want {
            if !fixed.lowercased().contains(w.lowercased()) {
                fails.append("missing \(w) in «\(fixed)» from «\(garbled)»")
            }
        }
        let hints = contextualStrings()
        if hints.count < 8 { fails.append("too few contextual hints: \(hints.count)") }
        if !hints.contains(where: { $0.lowercased() == "tray" }) {
            fails.append("contextual missing tray")
        }
        return fails
    }

    // MARK: - Private

    private static func matchAlias(_ core: String, terms: [Term]) -> String? {
        let key = core.lowercased()
        for term in terms {
            if term.spoken.lowercased() == key { return term.spoken }
            if term.enCanonical.lowercased() == key { return term.spoken }
            if term.asrAliases.contains(where: { $0.lowercased() == key }) {
                return term.spoken
            }
        }
        // Soft: prefix/edit distance 1–2 for Latin tool names ≥4 chars.
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
