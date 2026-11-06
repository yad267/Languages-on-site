import Foundation

/// Fuzzy match for Loop Mode STT vs reference EN. No Gemini / network.
enum PhraseSimilarity {
    /// Pass threshold for advancing (75%).
    static let passThreshold = 0.75
    /// Softer pass for TutorTalk (STT noise on site terms).
    static let talkPassThreshold = 0.65

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
        let collapsed = collapseRepeatedTarget(recognized, expected: expected)
        if score(recognized: collapsed, expected: expected) >= passThreshold { return true }
        // B4: «Handover» ≈ «hand over»; «turnoff» ≈ «turn off».
        let a = compactKey(collapsed)
        let b = compactKey(expected)
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        if score(recognized: a, expected: b) >= passThreshold { return true }
        // One clean hit inside longer STT (practice repeats already collapsed above).
        return windowContainsTarget(recognized: collapsed, expected: expected)
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

    /// STT contextualStrings: canon + compacted variant.
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
        talkScore(recognized: recognized, expected: expected) >= talkPassThreshold
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
            (" safepass ", " safe pass "),
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
        let bad = ["heart", "eyes", "reading my", "i am reading", "hard heart", "hi viz eyes"]
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

        return fails
    }
}
