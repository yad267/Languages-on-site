import Foundation

enum GrammarTense: String, CaseIterable, Identifiable {
    case present, past, future
    var id: String { rawValue }
    var titleRU: String {
        switch self {
        case .present: return "Present"
        case .past: return "Past"
        case .future: return "Future"
        }
    }
}

enum GrammarSpeechAct: String, CaseIterable, Identifiable {
    case statement, question, negative
    var id: String { rawValue }
    var titleRU: String {
        switch self {
        case .statement: return "Statement"
        case .question: return "Question"
        case .negative: return "Negative"
        }
    }
}

enum GrammarSubject: String, CaseIterable {
    case I, you, he, she, it, we, they

    /// they / I / you / we → do/don't; he/she/it → does/doesn't. NEVER they+does.
    var usesDoes: Bool {
        switch self {
        case .he, .she, .it: return true
        case .I, .you, .we, .they: return false
        }
    }

    var bePresent: String {
        switch self {
        case .I: return "am"
        case .he, .she, .it: return "is"
        case .you, .we, .they: return "are"
        }
    }

    var bePast: String {
        switch self {
        case .I, .he, .she, .it: return "was"
        case .you, .we, .they: return "were"
        }
    }
}

struct GrammarAssignment: Identifiable, Hashable {
    let id: UUID
    let kind: String
    let promptEN: String
    let promptRU: String
    let expected: [String]
    let siteTopic: String
    let verbLemma: String
    let tense: GrammarTense
    let speechAct: GrammarSpeechAct

    init(
        kind: String,
        promptEN: String,
        promptRU: String,
        expected: [String],
        siteTopic: String,
        verbLemma: String,
        tense: GrammarTense,
        speechAct: GrammarSpeechAct
    ) {
        self.id = UUID()
        self.kind = kind
        self.promptEN = promptEN
        self.promptRU = promptRU
        self.expected = expected
        self.siteTopic = siteTopic
        self.verbLemma = verbLemma
        self.tense = tense
        self.speechAct = speechAct
    }

    func matches(_ answer: String) -> Bool {
        let n = Self.norm(answer)
        return expected.map(Self.norm).contains(n)
    }

    private static func norm(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[^\w\s']+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

/// Invisible engine — NO 3×3 poster UI. Generates site micro-tasks.
@MainActor
enum GrammarPatterns {
    static let siteNouns = [
        "Safe Pass", "hard hat", "gate", "cable tray", "trunking", "Unistrut",
        "containment", "isolator", "panel", "CCTV camera", "ladder", "tools",
        "induction", "permit", "earth", "breaker",
    ]

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[^\w\s']+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func generate(
        verb: VerbEntry,
        tense: GrammarTense,
        speechAct: GrammarSpeechAct,
        siteTopic: String,
        subject: GrammarSubject = .they
    ) -> GrammarAssignment {
        let noun = siteSlot(for: siteTopic)
        let line = buildLine(verb: verb, tense: tense, speechAct: speechAct, subject: subject, noun: noun)
        let ruHint: String
        switch speechAct {
        case .statement: ruHint = "Скажи / напиши утверждение (\(tense.titleRU))."
        case .question: ruHint = "Сделай вопрос (\(tense.titleRU))."
        case .negative: ruHint = "Сделай отрицание (\(tense.titleRU))."
        }
        return GrammarAssignment(
            kind: "generate",
            promptEN: "Make a \(speechAct.rawValue) (\(tense.rawValue)) with «\(verb.lemma)» · \(noun)",
            promptRU: "\(ruHint) Тема: \(siteTopic).",
            expected: [line],
            siteTopic: siteTopic,
            verbLemma: verb.lemma,
            tense: tense,
            speechAct: speechAct
        )
    }

    static func fillGap(
        verb: VerbEntry,
        tense: GrammarTense,
        siteTopic: String,
        subject: GrammarSubject = .they
    ) -> GrammarAssignment {
        let noun = siteSlot(for: siteTopic)
        let full = buildLine(verb: verb, tense: tense, speechAct: .statement, subject: subject, noun: noun)
        let gapWord = gapToken(verb: verb, tense: tense, subject: subject)
        let prompt = full.replacingOccurrences(of: gapWord, with: "____", options: [.caseInsensitive])
        return GrammarAssignment(
            kind: "gap",
            promptEN: prompt,
            promptRU: "Вставь форму «\(verb.lemma)» (\(tense.titleRU)). \(verb.ru).",
            expected: [gapWord, gapWord.lowercased(), gapWord.capitalized],
            siteTopic: siteTopic,
            verbLemma: verb.lemma,
            tense: tense,
            speechAct: .statement
        )
    }

    static func transform(
        verb: VerbEntry,
        from: GrammarSpeechAct,
        to: GrammarSpeechAct,
        tense: GrammarTense,
        siteTopic: String,
        subject: GrammarSubject = .they
    ) -> GrammarAssignment {
        let noun = siteSlot(for: siteTopic)
        let source = buildLine(verb: verb, tense: tense, speechAct: from, subject: subject, noun: noun)
        let target = buildLine(verb: verb, tense: tense, speechAct: to, subject: subject, noun: noun)
        return GrammarAssignment(
            kind: "transform",
            promptEN: "→ \(to.titleRU): \(source)",
            promptRU: "Переделай в \(to.titleRU) (\(tense.titleRU)).",
            expected: [target],
            siteTopic: siteTopic,
            verbLemma: verb.lemma,
            tense: tense,
            speechAct: to
        )
    }

    static func worksheet(
        verbs: [VerbEntry],
        siteTopic: String,
        count: Int,
        includePhrasal: Bool,
        includeOpposite: Bool
    ) -> [GrammarAssignment] {
        TutorBankStore.ensureLoaded()
        var out: [GrammarAssignment] = []
        let acts: [GrammarSpeechAct] = [.statement, .question, .negative]
        let tenses = GrammarTense.allCases
        var pool = verbs.isEmpty ? Array(TutorBankStore.verbs.prefix(12)) : verbs
        if pool.isEmpty { return [] }
        var i = 0
        while out.count < count {
            let v = pool[i % pool.count]
            let tense = tenses[i % tenses.count]
            let act = acts[i % acts.count]
            let subj: GrammarSubject = (i % 2 == 0) ? .they : .you
            if i % 3 == 0 {
                out.append(fillGap(verb: v, tense: tense, siteTopic: siteTopic, subject: subj))
            } else if i % 3 == 1 {
                out.append(transform(verb: v, from: .statement, to: .question, tense: tense, siteTopic: siteTopic, subject: subj))
            } else {
                out.append(generate(verb: v, tense: tense, speechAct: act, siteTopic: siteTopic, subject: subj))
            }
            i += 1
            if i > count * 4 { break }
        }
        if includePhrasal, let p = TutorBankStore.phrasals.randomElement() {
            out.append(GrammarAssignment(
                kind: "phrasal",
                promptEN: "Translate / use: \(p.ru)",
                promptRU: "Напиши EN phrasal: \(p.ru)",
                expected: [p.en, p.en.lowercased()],
                siteTopic: siteTopic,
                verbLemma: p.en,
                tense: .present,
                speechAct: .statement
            ))
        }
        if includeOpposite, let o = TutorBankStore.opposites.randomElement() {
            out.append(GrammarAssignment(
                kind: "opposite",
                promptEN: "Opposite of «\(o.a)»?",
                promptRU: "Наоборот от «\(o.a)»: \(o.ru)",
                expected: [o.b, o.b.lowercased()],
                siteTopic: siteTopic,
                verbLemma: o.a,
                tense: .present,
                speechAct: .statement
            ))
        }
        return Array(out.prefix(count))
    }

    // MARK: - Line builder

    static func buildLine(
        verb: VerbEntry,
        tense: GrammarTense,
        speechAct: GrammarSpeechAct,
        subject: GrammarSubject,
        noun: String
    ) -> String {
        if verb.type == "be" || verb.lemma == "be" {
            return buildBe(tense: tense, speechAct: speechAct, subject: subject, noun: noun)
        }
        return buildDo(verb: verb, tense: tense, speechAct: speechAct, subject: subject, noun: noun)
    }

    private static func buildBe(
        tense: GrammarTense,
        speechAct: GrammarSpeechAct,
        subject: GrammarSubject,
        noun: String
    ) -> String {
        let be: String
        switch tense {
        case .present: be = subject.bePresent
        case .past: be = subject.bePast
        case .future: be = "will be"
        }
        let subj = subject.rawValue
        switch speechAct {
        case .statement:
            return "\(subj) \(be) at the \(noun)."
        case .negative:
            if tense == .future {
                return "\(subj) will not be at the \(noun)."
            }
            if tense == .present {
                let neg = subject == .I ? "am not" : (subject.usesDoes ? "isn't" : "aren't")
                // keep full forms for expected simplicity
                let n = subject == .I ? "am not" : "\(be) not"
                _ = neg
                return "\(subj) \(n) at the \(noun)."
            }
            return "\(subj) \(be) not at the \(noun)."
        case .question:
            if tense == .future {
                return "Will \(subj.lowercased()) be at the \(noun)?"
            }
            return "\(be.capitalized) \(subj.lowercased()) at the \(noun)?"
        }
    }

    private static func buildDo(
        verb: VerbEntry,
        tense: GrammarTense,
        speechAct: GrammarSpeechAct,
        subject: GrammarSubject,
        noun: String
    ) -> String {
        let subj = subject.rawValue
        let obj = objectPhrase(verb: verb, noun: noun)
        switch tense {
        case .present:
            switch speechAct {
            case .statement:
                let v = subject.usesDoes ? verb.third : verb.base
                return "\(subj) \(v) \(obj)."
            case .negative:
                if subject.usesDoes {
                    return "\(subj) doesn't \(verb.base) \(obj)."
                }
                return "\(subj) don't \(verb.base) \(obj)."
            case .question:
                if subject.usesDoes {
                    return "Does \(subj.lowercased()) \(verb.base) \(obj)?"
                }
                return "Do \(subj.lowercased()) \(verb.base) \(obj)?"
            }
        case .past:
            switch speechAct {
            case .statement:
                return "\(subj) \(verb.past) \(obj)."
            case .negative:
                return "\(subj) didn't \(verb.base) \(obj)."
            case .question:
                return "Did \(subj.lowercased()) \(verb.base) \(obj)?"
            }
        case .future:
            switch speechAct {
            case .statement:
                return "\(subj) will \(verb.base) \(obj)."
            case .negative:
                return "\(subj) won't \(verb.base) \(obj)."
            case .question:
                return "Will \(subj.lowercased()) \(verb.base) \(obj)?"
            }
        }
    }

    private static func gapToken(verb: VerbEntry, tense: GrammarTense, subject: GrammarSubject) -> String {
        switch tense {
        case .present:
            return subject.usesDoes ? verb.third : verb.base
        case .past:
            return verb.past
        case .future:
            return "will"
        }
    }

    private static func objectPhrase(verb: VerbEntry, noun: String) -> String {
        switch verb.lemma {
        case "sign": return "in at the \(noun)"
        case "put", "hang", "install", "mount", "fit": return "up the \(noun)"
        case "check", "test", "isolate", "switch", "turn": return "the \(noun)"
        case "wear": return "a hard hat"
        case "need", "have", "want", "get", "bring", "take", "give": return "the \(noun)"
        default: return "the \(noun)"
        }
    }

    private static func siteSlot(for topic: String) -> String {
        let t = topic.lowercased()
        if t.contains("safe") || t.contains("pass") { return "gate" }
        if t.contains("ppe") || t.contains("hat") { return "hard hat" }
        if t.contains("contain") || t.contains("tray") { return "cable tray" }
        if t.contains("cctv") { return "CCTV camera" }
        if t.contains("tool") { return "tools" }
        if t.contains("induct") { return "induction" }
        return siteNouns.randomElement() ?? "gate"
    }
}
