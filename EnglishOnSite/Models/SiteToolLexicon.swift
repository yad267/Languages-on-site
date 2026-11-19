import Foundation

/// One fastener / tool phrase the learner actually said (mixed RU/EN OK).
/// Keeps raw wording + structured fields so lessons can reuse their language.
struct LearnerToolTerm: Codable, Hashable, Identifiable {
    var id: String
    /// Exact span as spoken/typed (do not drop details).
    var raw: String
    /// bolt | screw | nut | washer | anchor | screwdriver | bit | drill | other
    var kind: String
    /// round | hex | countersunk | pan | cheese | unknown
    var headShape: String?
    /// phillips | flat | pozidriv | torx | hex | square | unknown
    var drive: String?
    var material: String?
    /// Ireland/UK site English for dialogue lines.
    var enCanonical: String
    var ruLabel: String

    var chipRU: String {
        var parts: [String] = [ruLabel]
        if let headShape { parts.append(Self.headRU[headShape] ?? headShape) }
        if let drive { parts.append(Self.driveRU[drive] ?? drive) }
        return parts.joined(separator: " · ")
    }

    private static let headRU: [String: String] = [
        "round": "круглая шляпка",
        "hex": "шестигранная",
        "countersunk": "потай",
        "pan": "полукруглая",
        "cheese": "цилиндрическая",
    ]

    private static let driveRU: [String: String] = [
        "phillips": "крест (Phillips)",
        "flat": "шлиц / плоская",
        "pozidriv": "Pozidriv",
        "torx": "Torx",
        "hex": "шестигранник",
        "square": "квадрат",
    ]
}

/// Offline extractor for mixed RU/EN tool & fastener talk.
/// Pitfall: never collapse “болт со шляпкой круглой под отвёртку плоскую” to bare “болт”.
enum SiteToolLexicon {
    /// Extract structured tools from an introduction / topic monologue.
    static func extract(from raw: String) -> [LearnerToolTerm] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return [] }

        var found: [LearnerToolTerm] = []
        var seen = Set<String>()

        // Windowed scans around each fastener/tool keyword so compound modifiers stay attached.
        let lower = text.lowercased()
        let keywords = kindKeywords
        for key in keywords {
            var searchFrom = lower.startIndex
            while let range = lower.range(of: key, range: searchFrom..<lower.endIndex) {
                let window = phraseWindow(in: text, around: range, radius: 56)
                if let term = parsePhrase(window) {
                    let dedupe = term.enCanonical.lowercased()
                    if seen.insert(dedupe).inserted {
                        found.append(term)
                    }
                }
                searchFrom = range.upperBound
            }
        }

        // Also catch pure EN compounds without RU stem nearby.
        for pattern in enCompoundPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                let span = ns.substring(with: m.range)
                if let term = parsePhrase(span) {
                    let dedupe = term.enCanonical.lowercased()
                    if seen.insert(dedupe).inserted {
                        found.append(term)
                    }
                }
            }
        }

        return found
    }

    /// Compact block for Gemini / coach prompts.
    static func promptBlock(for tools: [LearnerToolTerm], aboutRaw: String) -> String {
        var lines: [String] = []
        let about = aboutRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !about.isEmpty {
            lines.append("Learner introduction (keep their wording, mixed RU/EN OK):")
            lines.append(about)
        }
        if !tools.isEmpty {
            lines.append("Learner tools / fasteners (use these exact parts in the lesson):")
            for t in tools.prefix(12) {
                lines.append("- raw: «\(t.raw)» → EN: \(t.enCanonical) (kind=\(t.kind), head=\(t.headShape ?? "—"), drive=\(t.drive ?? "—"))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parse one phrase

    private static func parsePhrase(_ rawPhrase: String) -> LearnerToolTerm? {
        let phrase = rawPhrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard phrase.count >= 3 else { return nil }
        let t = phrase.lowercased()

        guard let kind = detectKind(t) else { return nil }
        let head = detectHead(t)
        let drive = detectDrive(t)
        let material = detectMaterial(t)

        // Skip bare kind with no extra detail only when the phrase is just the word itself.
        let tokens = t.split(separator: " ").map(String.init)
        if tokens.count <= 1, head == nil, drive == nil, material == nil {
            // Still keep single “болт/screwdriver” if user named it — but prefer compounds.
            // Allow single tool names so “phillips” + “отвёртка” from separate windows can merge via enCanonical uniqueness.
        }

        let en = buildEN(kind: kind, head: head, drive: drive, material: material, raw: t)
        let ru = buildRU(kind: kind, head: head, drive: drive, raw: phrase)
        let id = en.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9\-]"#, with: "", options: .regularExpression)

        return LearnerToolTerm(
            id: id.isEmpty ? UUID().uuidString : id,
            raw: phrase,
            kind: kind,
            headShape: head,
            drive: drive,
            material: material,
            enCanonical: en,
            ruLabel: ru
        )
    }

    private static func detectKind(_ t: String) -> String? {
        if t.contains("отвёрт") || t.contains("отверт") || t.contains("screwdriver") { return "screwdriver" }
        if t.contains("бита") || t.contains(" bit") || t.hasPrefix("bit ") { return "bit" }
        if t.contains("дрел") || t.contains("drill") { return "drill" }
        if t.contains("анкер") || t.contains("anchor") || t.contains("rawlplug") || t.contains("дюбел") { return "anchor" }
        if t.contains("шайб") || t.contains("washer") { return "washer" }
        if t.contains("гайк") || t.contains(" nut") || t.hasPrefix("nut") { return "nut" }
        if t.contains("шуруп") || t.contains("саморез") || t.contains("screw") { return "screw" }
        if t.contains("болт") || t.contains("bolt") { return "bolt" }
        if t.contains("винт") && !t.contains("отвёрт") { return "screw" }
        return nil
    }

    private static func detectHead(_ t: String) -> String? {
        if t.contains("потай") || t.contains("countersunk") || t.contains("countersink") { return "countersunk" }
        if t.contains("шестигран") || t.contains("hex head") || (t.contains("hex") && t.contains("head")) { return "hex" }
        if t.contains("полукруг") || t.contains("pan head") || t.contains("pan-head") { return "pan" }
        if t.contains("цилиндр") || t.contains("cheese head") { return "cheese" }
        if t.contains("кругл") || t.contains("round head") || t.contains("round-head")
            || (t.contains("шляпк") && t.contains("круг")) {
            return "round"
        }
        if t.contains("шляпк") {
            // "со шляпкой" without shape — keep unknown so we don't invent.
            return nil
        }
        return nil
    }

    private static func detectDrive(_ t: String) -> String? {
        if t.contains("pozidriv") || t.contains("pozi") || t.contains("позидрив") { return "pozidriv" }
        if t.contains("phillips") || t.contains("филипс") || t.contains("крест") || t.contains("крестов") {
            return "phillips"
        }
        if t.contains("torx") || t.contains("торкс") || t.contains("звёзд") || t.contains("звезд") { return "torx" }
        if t.contains("квадрат") || t.contains("square drive") || t.contains("robertson") { return "square" }
        if t.contains("шестигранн") && (t.contains("ключ") || t.contains("привод") || t.contains("drive") || t.contains("бит")) {
            return "hex"
        }
        // Flat / slotted — “плоск”, “шлиц”, “под отвёртку плоскую”, “flat head screwdriver” as drive for fastener
        if t.contains("плоск") || t.contains("шлиц") || t.contains("slotted")
            || t.contains("flat screw") || t.contains("flat driver")
            || (t.contains("flat") && (t.contains("отвёрт") || t.contains("screwdriver") || t.contains("шлиц"))) {
            return "flat"
        }
        if t.contains("под отвёртку") || t.contains("под отвертку") {
            // drive implied but shape of driver unknown
            return nil
        }
        return nil
    }

    private static func detectMaterial(_ t: String) -> String? {
        if t.contains("нержав") || t.contains("stainless") || t.contains("a2 ") || t.contains(" a4") { return "stainless" }
        if t.contains("оцинк") || t.contains("galvan") { return "galvanised" }
        if t.contains("латун") || t.contains("brass") { return "brass" }
        return nil
    }

    private static func buildEN(kind: String, head: String?, drive: String?, material: String?, raw: String) -> String {
        var parts: [String] = []
        if let material {
            parts.append(material == "galvanised" ? "galvanised" : material)
        }
        if let head {
            parts.append("\(head)-head")
        }
        if let drive {
            switch drive {
            case "phillips": parts.append("Phillips")
            case "flat": parts.append("slotted")
            case "pozidriv": parts.append("Pozidriv")
            case "torx": parts.append("Torx")
            case "hex": parts.append("hex-drive")
            case "square": parts.append("square-drive")
            default: break
            }
        }
        switch kind {
        case "bolt": parts.append("bolt")
        case "screw": parts.append("screw")
        case "nut": parts.append("nut")
        case "washer": parts.append("washer")
        case "anchor": parts.append("anchor")
        case "screwdriver":
            if let drive {
                switch drive {
                case "phillips": return "Phillips screwdriver"
                case "flat": return "flat screwdriver"
                case "pozidriv": return "Pozidriv screwdriver"
                case "torx": return "Torx screwdriver"
                default: break
                }
            }
            parts.append("screwdriver")
        case "bit":
            if let drive {
                return "\(drive == "phillips" ? "Phillips" : drive) bit"
            }
            parts.append("bit")
        case "drill": parts.append("drill")
        default: parts.append(kind)
        }

        // “под отвёртку плоскую” on a bolt → add purpose clause
        if kind == "bolt" || kind == "screw", raw.contains("под отвёрт") || raw.contains("под отверт") || raw.contains("for flat") {
            if drive == "flat" || raw.contains("плоск") {
                return parts.joined(separator: " ") + " for flat screwdriver"
            }
            if drive == "phillips" || raw.contains("крест") {
                return parts.joined(separator: " ") + " for Phillips screwdriver"
            }
        }
        return parts.joined(separator: " ")
    }

    private static func buildRU(kind: String, head: String?, drive: String?, raw: String) -> String {
        // Prefer keeping learner's compound if it's already rich.
        if raw.split(separator: " ").count >= 3 { return raw }
        var base: String
        switch kind {
        case "bolt": base = "болт"
        case "screw": base = "шуруп"
        case "nut": base = "гайка"
        case "washer": base = "шайба"
        case "anchor": base = "анкер"
        case "screwdriver": base = "отвёртка"
        case "bit": base = "бита"
        case "drill": base = "дрель"
        default: base = raw
        }
        var bits: [String] = [base]
        if let head {
            bits.append(LearnerToolTerm.headRULabel(head))
        }
        if let drive {
            bits.append(LearnerToolTerm.driveRULabel(drive))
        }
        return bits.joined(separator: " · ")
    }

    private static var kindKeywords: [String] {
        [
            "болт", "bolt", "шуруп", "саморез", "screw", "винт",
            "гайк", "nut", "шайб", "washer",
            "анкер", "anchor", "дюбел", "rawlplug",
            "отвёрт", "отверт", "screwdriver",
            "бита", " bit", "дрел", "drill",
        ]
    }

    private static var enCompoundPatterns: [String] {
        [
            #"\b(?:round|hex|pan|cheese|countersunk)[\s\-]?head\s+(?:phillips\s+|slotted\s+|pozidriv\s+|torx\s+)?(?:bolt|screw)s?\b"#,
            #"\b(?:phillips|slotted|pozidriv|torx|flat)\s+(?:head\s+)?(?:bolt|screw|screwdriver|bit)s?\b"#,
            #"\b(?:bolt|screw)s?\s+with\s+(?:a\s+)?(?:round|hex|pan|flat)\s+head\b"#,
        ]
    }

    /// DEBUG / smoke: compound RU descriptions must keep head + drive.
    static func selfCheckFailures() -> [String] {
        var fails: [String] = []
        func expect(_ raw: String, kind: String, head: String?, drive: String?) {
            let tools = extract(from: raw)
            guard let hit = tools.first(where: { $0.kind == kind }) ?? tools.first else {
                fails.append("no parse: \(raw)")
                return
            }
            if hit.kind != kind { fails.append("kind \(raw): got \(hit.kind)") }
            if hit.headShape != head { fails.append("head \(raw): got \(hit.headShape ?? "nil") want \(head ?? "nil")") }
            if hit.drive != drive { fails.append("drive \(raw): got \(hit.drive ?? "nil") want \(drive ?? "nil")") }
            if hit.raw.count < raw.count / 2 {
                fails.append("raw truncated \(raw) → \(hit.raw)")
            }
        }
        expect("болт со шляпкой круглой", kind: "bolt", head: "round", drive: nil)
        expect("болт со шляпкой круглой под отвёртку плоскую", kind: "bolt", head: "round", drive: "flat")
        expect("болт с крестом", kind: "bolt", head: nil, drive: "phillips")
        expect("phillips screwdriver and round-head bolt", kind: "screwdriver", head: nil, drive: "phillips")
        return fails
    }

    private static func phraseWindow(in text: String, around range: Range<String.Index>, radius: Int) -> String {
        let lower = text.lowercased()
        // Expand left/right by ~radius characters, then snap to whitespace.
        let startDist = text.distance(from: text.startIndex, to: range.lowerBound)
        let left = max(0, startDist - radius)
        let leftIdx = text.index(text.startIndex, offsetBy: left)
        let endDist = text.distance(from: text.startIndex, to: range.upperBound)
        let right = min(text.count, endDist + radius)
        let rightIdx = text.index(text.startIndex, offsetBy: right)
        var window = String(text[leftIdx..<rightIdx])

        // Trim to nearest sentence-ish separators so we don't glue unrelated clauses.
        let separators = CharacterSet(charactersIn: ".;!?\n")
        if let first = window.firstIndex(where: { separators.contains($0.unicodeScalars.first!) }) {
            // keep after previous separator if any — skip for simplicity
            _ = first
        }
        // Prefer cutting at commas only when far from keyword — keep “со шляпкой…, …” intact.
        window = window.trimmingCharacters(in: .whitespacesAndNewlines)
        // If window still huge, cut at conjunction boundaries away from keyword.
        if window.count > 90 {
            let mid = lower.distance(from: lower.startIndex, to: range.lowerBound) - left
            let ns = window as NSString
            if mid > 0, mid < ns.length {
                let before = ns.substring(to: mid)
                let after = ns.substring(from: mid)
                let cutBefore = before.components(separatedBy: " и ").last ?? before
                let cutAfter = after.components(separatedBy: " и ").first ?? after
                window = (cutBefore + cutAfter).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return window
    }
}

private extension LearnerToolTerm {
    static func headRULabel(_ head: String) -> String {
        switch head {
        case "round": return "круглая шляпка"
        case "hex": return "шестигранная шляпка"
        case "countersunk": return "потай"
        case "pan": return "полукруглая шляпка"
        case "cheese": return "цилиндрическая шляпка"
        default: return head
        }
    }

    static func driveRULabel(_ drive: String) -> String {
        switch drive {
        case "phillips": return "крест Phillips"
        case "flat": return "плоский шлиц"
        case "pozidriv": return "Pozidriv"
        case "torx": return "Torx"
        case "hex": return "шестигранник"
        case "square": return "квадрат"
        default: return drive
        }
    }
}
