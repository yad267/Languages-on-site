import Foundation

/// Fuzzy match for Loop Mode STT vs reference EN. No Gemini / network.
enum PhraseSimilarity {
    /// Pass threshold for advancing (75%).
    static let passThreshold = 0.75
    /// Softer pass for TutorTalk (STT noise on site terms).
    static let talkPassThreshold = 0.65
    /// Expected-token recall floor — blocks prefix auto-PASS
    /// («where is my» must not pass «where is my high-vis vest»).
    static let fullPhraseRecall = 0.85

    /// Similarity in 0…1 after normalization. Uses Levenshtein ratio.
    static func score(recognized: String, expected: String) -> Double {
        let a = normalize(recognized)
        let b = normalize(expected)
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }

        let dist = levenshtein(a, b)
        let denom = max(a.count, b.count)
        guard denom > 0 else { return 1 }
        let ratio = 1.0 - (Double(dist) / Double(denom))
        return min(1, max(0, ratio))
    }

    static func passes(recognized: String, expected: String) -> Bool {
        if passesRaw(recognized: recognized, expected: expected, useTalk: false) { return true }
        // Same progressive/filtered text the UI shows — if it covers the full target, accept.
        return passesViaDisplay(recognized: recognized, expected: expected, useTalk: false)
    }

    /// Raw-STT path only (no display filter). Used internally to avoid recursion with correctOnlyDisplay.
    private static func passesRaw(recognized: String, expected: String, useTalk: Bool) -> Bool {
        let collapsed = collapseRepeatedTarget(recognized, expected: expected)
        let a = compactKey(collapsed)
        let b = compactKey(expected)
        if !a.isEmpty, !b.isEmpty, a == b { return true }

        guard coversFullExpected(
            recognized: collapsed,
            expected: expected,
            useTalkNormalize: useTalk
        ) else {
            return false
        }

        if useTalk {
            return talkScore(recognized: collapsed, expected: expected) >= talkPassThreshold
        }

        if score(recognized: collapsed, expected: expected) >= passThreshold { return true }
        if a.isEmpty || b.isEmpty { return false }
        if score(recognized: a, expected: b) >= passThreshold { return true }
        return windowContainsTarget(recognized: collapsed, expected: expected)
    }

    /// Accept when progressive display already shows a *complete* target (junk STT skipped).
    /// Requires every expected token matched — a prefix like «where is my» must not PASS
    /// «where is my hard hat».
    private static func passesViaDisplay(recognized: String, expected: String, useTalk: Bool) -> Bool {
        let match = progressiveMatch(
            recognized: recognized,
            expected: expected,
            useTalkNormalize: useTalk
        )
        guard match.expectedCount > 0, match.matched == match.expectedCount else { return false }
        let shown = match.shown
        guard !shown.isEmpty else { return false }
        // Keep the 85% recall gate on the display-normalized text.
        guard coversFullExpected(
            recognized: shown,
            expected: expected,
            useTalkNormalize: useTalk
        ) else {
            return false
        }
        if useTalk {
            return talkScore(recognized: shown, expected: expected) >= talkPassThreshold
                || compactKey(shown) == compactKey(expected)
        }
        return score(recognized: shown, expected: expected) >= passThreshold
            || compactKey(shown) == compactKey(expected)
    }

    /// Spaces/hyphens removed — hand over / hand-over / handover.
    static func compactKey(_ text: String) -> String {
        normalize(text)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    /// «turn off turn off turn off» → display/match as one «turn off».
    static func collapseRepeatedTarget(_ recognized: String, expected: String) -> String {
        let raw = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        let exp = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !exp.isEmpty else { return raw }

        let eNorm = normalize(exp)
        let rNorm = normalize(raw)
        let eToks = eNorm.split(separator: " ").map(String.init)
        let rToks = rNorm.split(separator: " ").map(String.init)
        guard !eToks.isEmpty else { return raw }

        // Token repetition: E E E…
        if rToks.count >= eToks.count, rToks.count % eToks.count == 0 {
            let reps = rToks.count / eToks.count
            var allMatch = true
            for i in 0..<reps {
                let slice = Array(rToks[(i * eToks.count)..<((i + 1) * eToks.count)])
                if slice != eToks {
                    allMatch = false
                    break
                }
            }
            if allMatch { return exp }
        }

        // Compact repetition: turnoffturnoff → turn off
        let ec = compactKey(exp)
        let rc = compactKey(raw)
        if !ec.isEmpty, rc.count >= ec.count, rc.count % ec.count == 0 {
            let reps = rc.count / ec.count
            if reps >= 1, String(repeating: ec, count: reps) == rc {
                return exp
            }
        }

        // Leading copies of E then stop (e.g. "turn off turn off please" — keep first hit only if rest is noise)
        if rToks.count >= eToks.count * 2 {
            var copies = 0
            var idx = 0
            while idx + eToks.count <= rToks.count {
                let slice = Array(rToks[idx..<(idx + eToks.count)])
                if slice == eToks {
                    copies += 1
                    idx += eToks.count
                } else {
                    break
                }
            }
            if copies >= 2, idx == rToks.count {
                return exp
            }
            if copies >= 1, idx == rToks.count {
                return exp
            }
        }

        return raw
    }

    private static func windowContainsTarget(recognized: String, expected: String) -> Bool {
        let eToks = normalize(expected).split(separator: " ").map(String.init)
        let rToks = normalize(recognized).split(separator: " ").map(String.init)
        guard !eToks.isEmpty, rToks.count >= eToks.count else { return false }
        let b = compactKey(expected)
        for i in 0...(rToks.count - eToks.count) {
            let window = rToks[i..<(i + eToks.count)].joined(separator: " ")
            if score(recognized: window, expected: expected) >= passThreshold { return true }
            if compactKey(window) == b { return true }
        }
        return false
    }

    /// SFSpeech `contextualStrings` boost for Ireland site / PPE (hard hat, Safe Pass…).
    /// Kept under Apple’s ~100-phrase budget when merged with per-target hints.
    static let siteContextualHints: [String] = [
        "hard hat", "hard hats", "wear a hard hat", "put on your hard hat",
        "hi-vis", "hi vis", "high visibility", "high-vis vest",
        "Safe Pass", "safe pass", "Safe Pass card", "my Safe Pass",
        "PPE", "personal protective equipment",
        "safety boots", "steel toe", "steel-toe boots", "gloves", "goggles", "ear defenders",
        "helmet", "site induction", "induction", "sign in", "sign out",
        "cable tray", "cable basket", "Unistrut", "containment", "trunking",
        "clamp", "bolt", "lay down", "hand over", "toolbox talk",
        "CCTV", "zebs", "gate", "permit to work", "isolation",
        "scaffolding", "harness", "lanyard", "exclusion zone",
    ]

    /// Fix common EN site STT confusions before scoring / display.
    static func correctSiteASR(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        var s = " " + trimmed + " "
        let pairs: [(String, String)] = [
            ("hot hat", "hard hat"),
            ("hot hats", "hard hats"),
            ("heart hat", "hard hat"),
            ("heart hats", "hard hats"),
            ("heard hat", "hard hat"),
            ("heard hats", "hard hats"),
            ("hard heart", "hard hat"),
            ("hart hat", "hard hat"),
            ("hard at", "hard hat"),
            ("hard hit", "hard hat"),
            ("hard cat", "hard hat"),
            ("hard hat hat", "hard hat"),
            ("hi viz", "hi-vis"),
            ("high viz", "hi-vis"),
            ("safe past", "Safe Pass"),
            ("safe path", "Safe Pass"),
            ("safepass", "Safe Pass"),
            ("you nistrut", "Unistrut"),
            ("uni strut", "Unistrut"),
        ]
        for (wrong, right) in pairs {
            if let regex = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: wrong),
                options: [.caseInsensitive]
            ) {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: right)
            }
        }
        return s
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// STT contextualStrings: canon + compacted variant + site lexicon when relevant.
    static func sttVariants(for expected: String) -> [String] {
        let raw = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        var out = [raw]
        let compacted = raw
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let noSpace = compacted.replacingOccurrences(of: " ", with: "")
        if compacted != raw { out.append(compacted) }
        if noSpace.lowercased() != compacted.lowercased() { out.append(noSpace) }
        let words = compacted
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if words.count >= 2 {
            for i in 0..<(words.count - 1) {
                out.append("\(words[i]) \(words[i + 1])")
            }
        }
        let lower = compacted.lowercased()
        // Boost overlapping site terms + always keep hard hat / Safe Pass / hi-vis.
        for hint in siteContextualHints {
            let h = hint.lowercased()
            if lower.contains(h)
                || h.contains("hard hat")
                || h.contains("safe pass")
                || h.contains("hi-vis")
                || h.contains("hi vis")
                || h == "ppe" {
                out.append(hint)
            }
        }
        return out
    }

    /// Talk score: min(char Levenshtein, token F1) so STT garbage like
    /// «I save myself pass card here» does not pass «I have my Safe Pass…».
    static func talkScore(recognized: String, expected: String) -> Double {
        let a = normalizeTalk(recognized)
        let b = normalizeTalk(expected)
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let charRatio = score(recognized: a, expected: b)
        let tokenRatio = tokenF1(a, b)
        return min(charRatio, tokenRatio)
    }

    static func passesTalk(recognized: String, expected: String) -> Bool {
        if passesRaw(recognized: recognized, expected: expected, useTalk: true) { return true }
        return passesViaDisplay(recognized: recognized, expected: expected, useTalk: true)
    }

    /// Stable key for auto-finish hold — ignores minor raw STT jitter.
    static func stablePassKey(_ text: String) -> String {
        normalizeTalk(text)
    }

    /// True when recognized covers the full expected phrase (not a proper prefix).
    static func coversFullExpected(
        recognized: String,
        expected: String,
        useTalkNormalize: Bool
    ) -> Bool {
        let exp = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exp.isEmpty else { return true }
        guard !raw.isEmpty else { return false }

        let aCompact = compactKey(raw)
        let bCompact = compactKey(exp)
        if !aCompact.isEmpty, aCompact == bCompact { return true }

        let normFn: (String) -> String = useTalkNormalize ? normalizeTalk : normalize
        let recall = tokenRecall(normFn(raw), normFn(exp))
        if recall >= fullPhraseRecall { return true }

        // Short targets (1–2 tokens): require compact containment both ways or exact bag.
        let eToks = normFn(exp).split(separator: " ").map(String.init)
        if eToks.count <= 2 {
            return !aCompact.isEmpty && aCompact == bCompact
        }
        return false
    }

    /// Multiset token recall: how much of expected was heard.
    private static func tokenRecall(_ recognized: String, _ expected: String) -> Double {
        let wa = recognized.split(separator: " ").map(String.init)
        let wb = expected.split(separator: " ").map(String.init)
        if wb.isEmpty { return 1 }
        if wa.isEmpty { return 0 }
        var bag = [String: Int]()
        for w in wa { bag[w, default: 0] += 1 }
        var inter = 0
        for w in wb {
            if let c = bag[w], c > 0 {
                inter += 1
                bag[w] = c - 1
            }
        }
        return Double(inter) / Double(wb.count)
    }

    /// Multiset token F1 after normalizeTalk.
    private static func tokenF1(_ a: String, _ b: String) -> Double {
        let wa = a.split(separator: " ").map(String.init)
        let wb = b.split(separator: " ").map(String.init)
        if wa.isEmpty && wb.isEmpty { return 1 }
        if wa.isEmpty || wb.isEmpty { return 0 }
        var bag = [String: Int]()
        for w in wb { bag[w, default: 0] += 1 }
        var inter = 0
        for w in wa {
            if let c = bag[w], c > 0 {
                inter += 1
                bag[w] = c - 1
            }
        }
        let prec = Double(inter) / Double(wa.count)
        let rec = Double(inter) / Double(wb.count)
        guard prec + rec > 0 else { return 0 }
        return 2 * prec * rec / (prec + rec)
    }

    /// Site aliases before compare (hi-vis ≈ high visibility, hardhat ≈ hard hat).
    static func normalizeTalk(_ text: String) -> String {
        var s = " " + normalize(text) + " "
        let aliases: [(String, String)] = [
            (" hi vis ", " high visibility "),
            (" hivis ", " high visibility "),
            (" high-vis ", " high visibility "),
            (" hardhat ", " hard hat "),
            (" hard-hat ", " hard hat "),
            (" hot hat ", " hard hat "),
            (" heart hat ", " hard hat "),
            (" heard hat ", " hard hat "),
            (" hard heart ", " hard hat "),
            (" hart hat ", " hard hat "),
            (" hard at ", " hard hat "),
            (" hard hit ", " hard hat "),
            (" hard cat ", " hard hat "),
            (" safepass ", " safe pass "),
            (" safe past ", " safe pass "),
            (" safe path ", " safe pass "),
            (" cabletray ", " cable tray "),
            (" signin ", " sign in "),
            (" signout ", " sign out "),
            (" turnon ", " turn on "),
            (" turnoff ", " turn off "),
            (" handover ", " hand over "),
            (" hand-over ", " hand over "),
            (" pickup ", " pick up "),
            (" cleanup ", " clean up "),
            (" shutdown ", " shut down "),
            (" powerdown ", " power down "),
            (" layoff ", " lay off "),
            (" layout ", " lay out "),
            (" markout ", " mark out "),
            (" clearaway ", " clear away "),
            (" puton ", " put on "),
            (" takeoff ", " take off "),
        ]
        for (a, b) in aliases {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Heuristic: STT heard nonsense vs site target (heart/eyes vs hard hat).
    static func looksLikeSTTFail(recognized: String, expected: String) -> Bool {
        let r = normalizeTalk(recognized)
        let e = normalizeTalk(expected)
        guard !e.isEmpty else { return r.isEmpty }
        if r.isEmpty { return true }
        if talkScore(recognized: r, expected: e) >= talkPassThreshold { return false }
        let bad = [
            "heart", "eyes", "reading my", "i am reading", "hard heart",
            "hi viz eyes", "hot hat", "hart hat", "heart hat",
        ]
        let hitBad = bad.contains { r.contains($0) }
        let expectHat = e.contains("hard hat") || e.contains("hi vis") || e.contains("high visibility")
        if hitBad && expectHat { return true }
        // Very short vs long expected
        if r.split(separator: " ").count <= 2 && e.split(separator: " ").count >= 5 { return true }
        return talkScore(recognized: r, expected: e) < 0.35
    }

    /// Percent 0…100 for UI (after repeat-collapse).
    static func percent(recognized: String, expected: String) -> Int {
        let collapsed = collapseRepeatedTarget(recognized, expected: expected)
        return Int((score(recognized: collapsed, expected: expected) * 100).rounded())
    }

    /// Display helper: STT as heard + normalized (digits→words) when they differ.
    static func displayHeard(_ raw: String) -> (heard: String, normalized: String?) {
        let heard = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let norm = normalize(heard)
        let heardLoose = heard.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if norm.isEmpty || norm == heardLoose { return (heard, nil) }
        return (heard, norm)
    }

    /// UI box while listening / scoring against a known target.
    static func displayAgainstTarget(_ raw: String, expected: String) -> String {
        let collapsed = collapseRepeatedTarget(raw, expected: expected)
        let t = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : t
    }

    /// Live / review display for repeat-until-correct drills.
    /// Shows only target words matched so far (canonical casing from `expected`).
    /// Never surfaces incorrect STT tokens. Full PASS → full expected phrase.
    /// - Parameter useTalkThreshold: TutorTalk soft pass (0.65 + talk normalize).
    static func correctOnlyDisplay(
        recognized: String,
        expected: String,
        useTalkThreshold: Bool = false
    ) -> String {
        let exp = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exp.isEmpty else { return "" }
        let cleaned = correctSiteASR(recognized)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        let collapsed = collapseRepeatedTarget(cleaned, expected: exp)
        // Use raw path only — avoids recursion with passesViaDisplay.
        if passesRaw(recognized: collapsed, expected: exp, useTalk: useTalkThreshold) {
            return exp
        }
        if !compactKey(collapsed).isEmpty, compactKey(collapsed) == compactKey(exp) {
            return exp
        }

        let match = progressiveMatch(
            recognized: collapsed,
            expected: exp,
            useTalkNormalize: useTalkThreshold
        )
        if match.matched == match.expectedCount, match.expectedCount > 0 {
            return exp
        }
        return match.shown
    }

    private struct ProgressiveMatch {
        let shown: String
        let matched: Int
        let expectedCount: Int
    }

    /// Progressive target words matched so far (junk STT skipped). Shared by UI + PASS.
    private static func progressiveMatch(
        recognized: String,
        expected: String,
        useTalkNormalize: Bool
    ) -> ProgressiveMatch {
        let exp = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = correctSiteASR(recognized)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exp.isEmpty, !cleaned.isEmpty else {
            return ProgressiveMatch(shown: "", matched: 0, expectedCount: 0)
        }

        let collapsed = collapseRepeatedTarget(cleaned, expected: exp)
        let normFn: (String) -> String = useTalkNormalize ? normalizeTalk : normalize
        let eNorm = normFn(exp).split(separator: " ").map(String.init)
        let expectedCount = eNorm.count
        guard expectedCount > 0 else {
            return ProgressiveMatch(shown: "", matched: 0, expectedCount: 0)
        }

        if !compactKey(collapsed).isEmpty, compactKey(collapsed) == compactKey(exp) {
            return ProgressiveMatch(shown: exp, matched: expectedCount, expectedCount: expectedCount)
        }

        let displayToks = exp
            .split { $0.isWhitespace || $0.isNewline }
            .map(String.init)
            .filter { !$0.isEmpty }
        let rNorm = normFn(collapsed).split(separator: " ").map(String.init)
        guard !rNorm.isEmpty else {
            return ProgressiveMatch(shown: "", matched: 0, expectedCount: expectedCount)
        }

        let showToks: [String] = {
            if displayToks.count == eNorm.count { return displayToks }
            return eNorm
        }()

        var ri = 0
        var matched = 0
        for ei in 0..<eNorm.count {
            var found = false
            while ri < rNorm.count {
                let r = rNorm[ri]
                ri += 1
                if tokensRoughlyMatch(r, eNorm[ei]) {
                    found = true
                    break
                }
            }
            if found {
                matched += 1
            } else {
                break
            }
        }

        if matched == 0 {
            let rc = compactKey(collapsed)
            guard !rc.isEmpty else {
                return ProgressiveMatch(shown: "", matched: 0, expectedCount: expectedCount)
            }
            var built = ""
            var covered = 0
            for (i, tok) in eNorm.enumerated() {
                let next = built + tok
                if rc == next || rc.hasPrefix(next) {
                    covered = i + 1
                    built = next
                    if rc == next { break }
                } else {
                    break
                }
            }
            let shown = covered > 0 ? showToks.prefix(covered).joined(separator: " ") : ""
            return ProgressiveMatch(shown: shown, matched: covered, expectedCount: expectedCount)
        }

        let shown = showToks.prefix(matched).joined(separator: " ")
        return ProgressiveMatch(shown: shown, matched: matched, expectedCount: expectedCount)
    }

    /// PPE / site STT confusions that should count as the same token in progressive match.
    private static let confusableTokenGroups: [[String]] = [
        ["hard", "heart", "heard", "hart", "hot"],
        ["hat", "hats", "had"],
        ["vis", "viz", "visibility"],
        ["pass", "past", "path"],
    ]

    /// Single-token match for progressive correct-only UI.
    private static func tokensRoughlyMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.isEmpty || b.isEmpty { return false }
        if compactKey(a) == compactKey(b) { return true }
        for group in confusableTokenGroups {
            if group.contains(a), group.contains(b) { return true }
        }
        // Tight fuzzy — avoid accepting unrelated short words.
        if a.count >= 3, b.count >= 3, score(recognized: a, expected: b) >= 0.84 {
            return true
        }
        // One-edit for length≥4 (heart↔hard is 2 edits; covered by confusable groups).
        if a.count >= 4, b.count >= 4, score(recognized: a, expected: b) >= 0.75 {
            return true
        }
        return false
    }

    /// True when progressive match has every expected token (trailing words included).
    static func isCompleteProgressiveMatch(
        recognized: String,
        expected: String,
        useTalkNormalize: Bool = true
    ) -> Bool {
        let m = progressiveMatch(
            recognized: recognized,
            expected: expected,
            useTalkNormalize: useTalkNormalize
        )
        return m.expectedCount > 0 && m.matched == m.expectedCount
    }

    /// Lowercase, strip punctuation (hyphen → space so two-way → two way),
    /// expand digit runs / digit+suffix (20, 2way) to English words 0…100.
    /// Both sides use the same path → «twenty» ≈ «20».
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map { s -> Character in
            if CharacterSet.alphanumerics.contains(s) || s == " " {
                return Character(s)
            }
            // Keep word boundaries for compounds like two-way / two–way.
            if s == "-" || s == "–" || s == "—" {
                return " "
            }
            return " "
        }
        let cleaned = String(scalars)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let tokens = cleaned.split(separator: " ").map(String.init)
        let expanded = tokens.flatMap { expandToken($0) }
        return expanded.joined(separator: " ")
    }

    // MARK: - Digits → English words (0…100)

    private static func expandToken(_ token: String) -> [String] {
        if token.isEmpty { return [] }

        // Pure integer 0…100 → words.
        if let n = Int(token), (0...100).contains(n) {
            return words(for: n)
        }

        // Leading digits + letters: "2way" → two + way; "20th" → twenty + th
        var i = token.startIndex
        while i < token.endIndex, token[i].isNumber {
            i = token.index(after: i)
        }
        if i > token.startIndex, i < token.endIndex {
            let dig = String(token[token.startIndex..<i])
            let rest = String(token[i...])
            if rest.allSatisfy(\.isLetter), let num = Int(dig), (0...100).contains(num) {
                var out = words(for: num)
                out.append(rest)
                return out
            }
        }

        return [token]
    }

    private static func words(for n: Int) -> [String] {
        let ones = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
            "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
            "seventeen", "eighteen", "nineteen",
        ]
        let tens = [
            "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        ]

        if n < 20 { return [ones[n]] }
        if n == 100 { return ["one", "hundred"] }
        let t = n / 10
        let o = n % 10
        if o == 0 { return [tens[t]] }
        return [tens[t], ones[o]]
    }

    // MARK: - Levenshtein

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        if n == 0 { return m }
        if m == 0 { return n }

        var prev = Array(0...m)
        var curr = [Int](repeating: 0, count: m + 1)

        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,
                    curr[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            prev = curr
        }
        return prev[m]
    }

    // MARK: - Self-check (no XCTest target)

    /// Returns failures; empty = all green. Call from DEBUG / Preview.
    static func selfCheckFailures() -> [String] {
        var fails: [String] = []

        func check(_ name: String, got: String, expected: String, shouldPass: Bool) {
            let okPass = passes(recognized: got, expected: expected)
            let s = score(
                recognized: collapseRepeatedTarget(got, expected: expected),
                expected: expected
            )
            let ok = shouldPass ? okPass : !okPass
            if !ok {
                fails.append(
                    "\(name): pass=\(okPass) score=\(String(format: "%.2f", s)) expectedPass=\(shouldPass) got=\"\(got)\" ref=\"\(expected)\" collapsed=\"\(collapseRepeatedTarget(got, expected: expected))\" display=\"\(displayAgainstTarget(got, expected: expected))\""
                )
            }
        }

        // Display dedupe must show one target, not stacked repeats.
        let disp = displayAgainstTarget("Turn off turn off turn off", expected: "turn off")
        if normalize(disp) != normalize("turn off") {
            fails.append("display-dedupe: got=\"\(disp)\"")
        }

        // correctOnlyDisplay: never surface wrong STT; progressive target words only.
        let wrongOnly = correctOnlyDisplay(
            recognized: "banana refrigerator purple",
            expected: "I've got my hard hat on, boss"
        )
        if !wrongOnly.isEmpty {
            fails.append("correctOnly-wrong: got=\"\(wrongOnly)\"")
        }
        let prefixOK = correctOnlyDisplay(
            recognized: "I've got my",
            expected: "I've got my hard hat on, boss"
        )
        if normalize(prefixOK) != normalize("I've got my") {
            fails.append("correctOnly-prefix: got=\"\(prefixOK)\"")
        }
        let junkThenOK = correctOnlyDisplay(
            recognized: "um uh I've got my",
            expected: "I've got my hard hat on, boss"
        )
        if normalize(junkThenOK) != normalize("I've got my") {
            fails.append("correctOnly-skip-junk: got=\"\(junkThenOK)\"")
        }
        let fullOK = correctOnlyDisplay(
            recognized: "I've got my hard hat on boss",
            expected: "I've got my hard hat on, boss"
        )
        if normalize(fullOK) != normalize("I've got my hard hat on, boss") {
            fails.append("correctOnly-full: got=\"\(fullOK)\"")
        }
        let talkPassShow = correctOnlyDisplay(
            recognized: "wear a hot hat",
            expected: "wear a hard hat",
            useTalkThreshold: true
        )
        if normalize(talkPassShow) != normalize("wear a hard hat") {
            fails.append("correctOnly-talk-alias: got=\"\(talkPassShow)\"")
        }

        // Prefix must NOT pass the full target (STT early-cutoff bug).
        let hiVis = "where is my high-vis vest"
        if passes(recognized: "where is my", expected: hiVis) {
            fails.append("prefix-pass-drill: where is my")
        }
        if passesTalk(recognized: "where is my", expected: hiVis) {
            fails.append("prefix-pass-talk: where is my")
        }
        if passes(recognized: "where is my high", expected: hiVis) {
            fails.append("prefix-pass-drill: where is my high")
        }
        if passesTalk(recognized: "where is my high", expected: hiVis) {
            fails.append("prefix-pass-talk: where is my high")
        }
        if !passes(recognized: "where is my high-vis vest", expected: hiVis) {
            fails.append("full-phrase-should-pass-drill: high-vis vest")
        }
        if !passesTalk(recognized: "where is my high vis vest", expected: hiVis) {
            fails.append("full-phrase-should-pass-talk: high-vis vest")
        }
        if !coversFullExpected(
            recognized: "where is my high-vis vest",
            expected: hiVis,
            useTalkNormalize: true
        ) {
            fails.append("full-coverage-high-vis")
        }

        // Display-complete with junk fillers must PASS (UI already shows full target).
        let junkFull = "um yeah where is my high-vis vest please"
        if !passes(recognized: junkFull, expected: hiVis) {
            fails.append("display-complete-pass-drill: junk fillers")
        }
        if !passesTalk(recognized: junkFull, expected: hiVis) {
            fails.append("display-complete-pass-talk: junk fillers")
        }
        // Prefix still blocked even via display path.
        if passes(recognized: "um where is my", expected: hiVis) {
            fails.append("display-prefix-still-blocked")
        }
        let hardHat = "where is my hard hat"
        if passes(recognized: "where is my", expected: hardHat)
            || passesTalk(recognized: "where is my", expected: hardHat) {
            fails.append("prefix-must-not-pass-hard-hat")
        }
        if !passes(recognized: "where is my hard hat", expected: hardHat) {
            fails.append("full-hard-hat-should-pass-drill")
        }
        if !passesTalk(recognized: "where is my hard hat", expected: hardHat) {
            fails.append("full-hard-hat-should-pass-talk")
        }
        // STT often hears heart/hot for hard — must still complete progressive + PASS.
        if !passesTalk(recognized: "where is my heart hat", expected: hardHat) {
            fails.append("heart-hat-should-pass-talk")
        }
        if !isCompleteProgressiveMatch(
            recognized: "where is my heart hat",
            expected: hardHat,
            useTalkNormalize: true
        ) {
            fails.append("heart-hat-progressive-complete")
        }

        check(
            "near-perfect",
            got: "Pass me the drill please",
            expected: "Pass me the drill, please.",
            shouldPass: true
        )
        check(
            "wrong-phrase",
            got: "Where is the toilet",
            expected: "Pass me the drill, please.",
            shouldPass: false
        )
        check(
            "close-words",
            got: "here battery is charged",
            expected: "Here. Battery is charged.",
            shouldPass: true
        )
        check(
            "twenty-vs-20",
            got: "I need 20 metres of cable",
            expected: "I need twenty metres of cable",
            shouldPass: true
        )
        check(
            "20-vs-twenty",
            got: "I need twenty metres of cable",
            expected: "I need 20 metres of cable",
            shouldPass: true
        )
        check(
            "two-way",
            got: "check the 2 way radio",
            expected: "Check the two-way radio",
            shouldPass: true
        )
        check(
            "hundred",
            got: "about 100 volts",
            expected: "about one hundred volts",
            shouldPass: true
        )
        check(
            "handover-vs-hand-over",
            got: "Handover",
            expected: "hand over",
            shouldPass: true
        )
        check(
            "hand-over-hyphen",
            got: "hand-over",
            expected: "hand over",
            shouldPass: true
        )
        check(
            "turnoff-vs-turn-off",
            got: "turnoff",
            expected: "turn off",
            shouldPass: true
        )
        check(
            "repeat-turn-off",
            got: "Turn off turn off turn off",
            expected: "turn off",
            shouldPass: true
        )
        check(
            "repeat-compact-turnoff",
            got: "turnoff turnoff",
            expected: "turn off",
            shouldPass: true
        )

        let fixedHat = correctSiteASR("Please wear your hot hat")
        if !fixedHat.lowercased().contains("hard hat") {
            fails.append("correctSiteASR hot→hard: got=\"\(fixedHat)\"")
        }
        if !passesTalk(recognized: "wear a hot hat", expected: "wear a hard hat") {
            fails.append("talk-pass after hot hat alias")
        }

        return fails
    }
}
