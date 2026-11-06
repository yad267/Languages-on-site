import Foundation

struct RememberAnalysis: Equatable {
    var en: String
    var ru: String
    var tipRu: String
    var tag: LibraryTag
    var sayIt: String
    var colloquialNoteRu: String?
}

enum TranslateSourceHint: String {
    case en, ru, auto
}

/// One place for Gemini model id + 404 fallback chain (translate / remember / lessons).
enum GeminiConfig {
    /// Preferred model (Settings + logs).
    static let model = "gemini-3.5-flash-lite"

    /// On HTTP 404 (model gone) try next in order.
    static let modelFallbackChain: [String] = [
        "gemini-3.5-flash-lite",
        "gemini-3.8-flash",
        "gemini-2.5-flash",
    ]

    static let timeout: TimeInterval = 20
    static let lessonTimeout: TimeInterval = 25

    static func endpoint(for modelId: String) -> String {
        "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):generateContent"
    }

    /// Last model that returned 2xx (for UI / debug).
    static var lastUsedModel: String = model
}

enum GeminiRequestError: LocalizedError, Equatable {
    case noAPIKey
    case rateLimited
    case httpStatus(Int, String)
    case network(String)
    case emptyResponse
    case badJSON
    case blocked(String)
    case tooShort

    /// Short RU line for on-screen UI (no secrets).
    var shortRU: String {
        switch self {
        case .noAPIKey:
            return "Нет ключа Gemini в Настройках"
        case .rateLimited:
            return "Подожди 2 сек — rate-limit"
        case .httpStatus(let code, let detail):
            if code == 400 || code == 403 {
                return "Плохой ключ / HTTP \(code)"
            }
            if code == 429 {
                return "Лимит Gemini (HTTP 429)"
            }
            if !detail.isEmpty { return "HTTP \(code): \(detail)" }
            return "HTTP \(code)"
        case .network:
            return "Нет сети / таймаут Gemini"
        case .emptyResponse:
            return "Пустой ответ Gemini"
        case .badJSON:
            return "Gemini: не разобрал JSON"
        case .blocked(let m):
            return m.isEmpty ? "Gemini заблокировал ответ" : m
        case .tooShort:
            return "Фраза слишком короткая"
        }
    }

    var errorDescription: String? { shortRU }
}

enum GeminiLessonError: LocalizedError, Equatable {
    case noAPIKey
    case geminiDisabled
    case rateLimited
    case offTopic(String)
    case invalidResponse
    case network
    case request(GeminiRequestError)

    var errorDescription: String? {
        switch self {
        case .noAPIKey, .geminiDisabled:
            return "Нужен Gemini в Настройках, чтобы создать урок"
        case .rateLimited:
            return "Подожди пару секунд и попробуй снова"
        case .offTopic(let msg):
            return msg.isEmpty ? "Тема не про объект — уточни (электрика / CCTV / tools / safety)" : msg
        case .invalidResponse:
            return "Не собралось, попробуй короче тему"
        case .network:
            return "Нет ответа от Gemini — проверь сеть и ключ"
        case .request(let e):
            return e.shortRU
        }
    }
}

@MainActor
final class GeminiSiteCoachService {
    static let shared = GeminiSiteCoachService()

    private var lastRequestAt: Date = .distantPast
    private var lastLessonRequestAt: Date = .distantPast
    private let minInterval: TimeInterval = 2
    private let minLessonInterval: TimeInterval = 5

    /// Last tip/translate error for UI (cleared on success).
    private(set) var lastTipError: GeminiRequestError?

    private let systemPrompt = """
    Ты — коуч разговорного EN↔RU для электрика/CCTV/монтажника в Ireland (residential).
    Уровень пользователя A1–A2.
    Правила:
    - Ireland/UK terms (consumer unit, MCB, two-way switch, isolator). Не US/NEC (panel, ground wire как default).
    - Не жильё/аренда, не стоицизм, не общий travel-smalltalk.
    - Карточка/поле en = правильная письменная форма; если в transcript жаргон/сокращение — вынеси в colloquial_note_ru, а en нормализуй.
    - Ответ ТОЛЬКО JSON без markdown:
      {"en":"...","ru":"...","tip_ru":"...","tag":"electrical","say_it":"...","colloquial_note_ru":null}
    - tip_ru может быть "" если не нужен. tag обязателен.
    - Коротко. tip_ru ≤ 120 символов. Без лекций.
    - tag один из: electrical, cctv, sockets, safety, tools, other
    """

    private let lessonSystemPrompt = """
    Ты создаёшь короткий roleplay-урок EN↔RU для электрика/CCTV/монтажника на объекте в Ireland (residential).
    Уровень A1–A2. Диалог на объекте, НЕ лекция.

    Правила языка:
    - Ireland/UK terms only: consumer unit, MCB, two-way, isolator, kopex, back box, earth, live, fused spur, ring…
    - Не US/NEC default (panel, ground wire как основное слово).
    - Каждая реплика: зеркало en + ru.
    - 6–10 lines диалога.
    - 2–4 реплики electrician с "practice": true (для «Скажи это»).
    - Ровно 2 фразы в say_today.
    - tip_ru коротко, где полезно (можно null / опустить).
    - your_role всегда "electrician"; partner_role: "foreman" | "client" | "colleague".
    - tags: подмножество ["electrical","cctv","sockets","safety","tools","other"].

    Ответ ТОЛЬКО JSON одного объекта (без markdown):
    {
      "id":"user-temp",
      "title_ru":"...",
      "tags":["electrical"],
      "scene_ru":"...",
      "your_role":"electrician",
      "partner_role":"foreman",
      "lines":[{"en":"...","ru":"...","role":"foreman","tip_ru":"...","practice":false}],
      "say_today":[{"en":"...","ru":"..."},{"en":"...","ru":"..."}],
      "created_by":"user_gemini",
      "topic_raw":"..."
    }

    Если тема совсем не про объект/электрика/CCTV/инструмент/safety — сделай ближайший site-урок
    ИЛИ верни: {"error":"off_topic","message_ru":"..."}.
    """

    func analyzeRemember(
        transcript: String,
        preferredLocale: String,
        lessonTags: [String] = []
    ) async -> RememberAnalysis? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }

        var user = """
        Задача: извлеки 1 самую полезную фразу для работы на объекте.
        preferred_locale: \(preferredLocale)
        transcript:
        \(trimmed)
        """
        if !lessonTags.isEmpty {
            user += "\nlesson_tags: \(lessonTags.joined(separator: ", "))"
        }

        do {
            let raw = try await generateJSON(
                userText: user,
                system: systemPrompt,
                timeout: GeminiConfig.timeout,
                maxTokens: 512,
                temperature: 0.2,
                skipRateLimit: false
            )
            guard let analysis = parseRemember(raw) else {
                lastTipError = .badJSON
                print("[gemini] error=badJSON remember parse failed")
                return nil
            }
            lastTipError = nil
            return analysis
        } catch let e as GeminiRequestError {
            lastTipError = e
            print("[gemini] error=\(e.shortRU)")
            return nil
        } catch {
            lastTipError = .network(error.localizedDescription)
            print("[gemini] error=network \(error.localizedDescription)")
            return nil
        }
    }

    func translate(text: String, sourceHint: TranslateSourceHint) async -> TranslationResult? {
        do {
            return try await translateThrowing(text: text, sourceHint: sourceHint)
        } catch {
            return nil
        }
    }

    func translateThrowing(text: String, sourceHint: TranslateSourceHint) async throws -> TranslationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else { throw GeminiRequestError.tooShort }

        let user = """
        Переведи ЦЕЛИКОМ всё сказанное/написанное для объекта Ireland (electrical/CCTV/tools/safety).
        Не обрезай, не суммаризируй — каждое слово фразы должно попасть в en и ru.
        source_hint: \(sourceHint.rawValue)
        text: \(trimmed)
        Ответ ТОЛЬКО JSON:
        {"en":"...полный EN...","ru":"...полный RU...","tip_ru":"...","tag":"electrical","say_it":"...","colloquial_note_ru":null}
        """

        let raw = try await generateJSON(
            userText: user,
            system: systemPrompt,
            timeout: GeminiConfig.timeout,
            maxTokens: 1024,
            temperature: 0.2,
            skipRateLimit: false
        )

        guard let analysis = parseRemember(raw) else {
            lastTipError = .badJSON
            print("[gemini] error=badJSON translate body=\(raw.prefix(180))")
            throw GeminiRequestError.badJSON
        }
        lastTipError = nil

        let sourceIsRU: Bool
        switch sourceHint {
        case .ru: sourceIsRU = true
        case .en: sourceIsRU = false
        case .auto: sourceIsRU = isMostlyRussian(trimmed)
        }

        if sourceIsRU {
            return TranslationResult(
                sourceText: trimmed,
                translatedText: analysis.en,
                sourceIsRussian: true,
                matched: true,
                tipRu: analysis.tipRu,
                tag: analysis.tag,
                fallbackSpokenRU: nil,
                viaGemini: true
            )
        }
        return TranslationResult(
            sourceText: trimmed,
            translatedText: analysis.ru,
            sourceIsRussian: false,
            matched: true,
            tipRu: analysis.tipRu,
            tag: analysis.tag,
            fallbackSpokenRU: nil,
            viaGemini: true
        )
    }

    /// B17: canon conversational EN + RU (not telegraph; not raw STT).
    func canonizePhrase(
        text: String,
        sourceIsRussian: Bool,
        phrasalHint: String? = nil
    ) async throws -> CanonPhrase {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { throw GeminiRequestError.tooShort }
        let hint = (phrasalHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let phrasalLine = hint.isEmpty ? "" : "Must naturally use phrasal «\(hint)»."
        let user: String
        if sourceIsRussian {
            user = """
            Ученик сказал/написал по-русски. Дай КАНОН для Ireland site A1–A2:
            - en: полная разговорная правильная фраза (не телеграф, есть глагол)
            - ru: естественный перевод
            \(phrasalLine)
            text: \(trimmed)
            JSON only: {"en":"...","ru":"...","tip_ru":"...","ok":true}
            """
        } else {
            user = """
            Ученик сказал/написал по-английски. Исправь грамматику и разговорность A1–A2 Ireland site.
            Сохрани смысл. Не телеграф. Полное предложение.
            \(phrasalLine)
            text: \(trimmed)
            JSON only: {"en":"...canonical EN...","ru":"...RU...","tip_ru":"...short tip...","ok":true}
            """
        }
        let raw = try await generateJSON(
            userText: user,
            system: systemPrompt,
            timeout: GeminiConfig.timeout,
            maxTokens: 512,
            temperature: 0.25,
            skipRateLimit: false
        )
        guard let obj = decodeLooseJSON(raw),
              let en = (obj["en"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !en.isEmpty else {
            throw GeminiRequestError.badJSON
        }
        let ru = (obj["ru"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tip = (obj["tip_ru"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CanonPhrase(
            en: en,
            ru: ru.isEmpty ? (sourceIsRussian ? trimmed : "(перевод позже)") : ru,
            tipRu: tip,
            sourceIsRussian: sourceIsRussian,
            viaGemini: true
        )
    }

    /// B13: short feedback on learner sentence with a phrasal.
    func reviewPhrasalUse(phrasal: String, heard: String) async throws -> (ok: Bool, en: String, ru: String) {
        let p = phrasal.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.count >= 2, h.count >= 2 else { throw GeminiRequestError.tooShort }
        let user = """
        Phrasal: «\(p)»
        Learner said: «\(h)»
        Ireland site A1–A2. Short check:
        - ok: true if natural+correct enough
        - en: corrected full sentence with the phrasal
        - ru: short RU note (1 sentence)
        JSON only: {"ok":true,"en":"...","ru":"..."}
        """
        let raw = try await generateJSON(
            userText: user,
            system: systemPrompt,
            timeout: GeminiConfig.timeout,
            maxTokens: 400,
            temperature: 0.2,
            skipRateLimit: false
        )
        guard let obj = decodeLooseJSON(raw) else { throw GeminiRequestError.badJSON }
        let ok = (obj["ok"] as? Bool) ?? false
        let en = (obj["en"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? h
        let ru = (obj["ru"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (ok, en.isEmpty ? h : en, ru)
    }

    /// Create a full site lesson from a free-text topic. Timeout 20s, rate-limit 5s.
    func generateLesson(topic: String) async throws -> Lesson {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { throw GeminiLessonError.invalidResponse }

        let apiKey = Self.sanitizedAPIKey()
        guard !apiKey.isEmpty else { throw GeminiLessonError.noAPIKey }

        let now = Date()
        guard now.timeIntervalSince(lastLessonRequestAt) >= minLessonInterval else {
            throw GeminiLessonError.rateLimited
        }
        lastLessonRequestAt = now

        let user = """
        Создай урок по теме пользователя (Ireland site).
        topic: \(trimmed)
        Заполни topic_raw исходной темой. id можешь поставить временный — клиент перезапишет.
        """

        let raw: String
        do {
            raw = try await generateJSON(
                userText: user,
                system: lessonSystemPrompt,
                timeout: GeminiConfig.lessonTimeout,
                maxTokens: 4096,
                temperature: 0.35,
                skipRateLimit: true
            )
        } catch let e as GeminiRequestError {
            throw GeminiLessonError.request(e)
        }

        if let off = parseOffTopic(raw) {
            throw GeminiLessonError.offTopic(off)
        }

        guard var lesson = parseLesson(raw) else {
            throw GeminiLessonError.invalidResponse
        }

        let id = LessonTopicParser.makeUserLessonId(topic: trimmed)
        lesson = Lesson(
            id: id,
            titleRu: lesson.titleRu,
            tags: lesson.tags.isEmpty ? ["other"] : lesson.tags,
            sceneRu: lesson.sceneRu,
            yourRole: lesson.yourRole.isEmpty ? "electrician" : lesson.yourRole,
            partnerRole: lesson.partnerRole.isEmpty ? "foreman" : lesson.partnerRole,
            lines: lesson.lines,
            sayToday: lesson.sayToday,
            createdBy: "user_gemini",
            topicRaw: trimmed
        )

        guard let ok = lesson.validated() else {
            throw GeminiLessonError.invalidResponse
        }
        return ok
    }

    /// Parse pasted site dialogue into RoleplayScript (roles + turns).
    func parseRoleplay(text: String) async throws -> RoleplayScript {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { throw RoleplayParseError.tooShort }

        let system = """
        You parse construction-site technical dialogues (electricians, CCTV, installers, Ireland/UK English).
        Output ONLY JSON:
        {
          "title_ru": string,
          "scene_ru": string,
          "roles": [{"name": string, "slot": "a"|"b"}],
          "lines": [{"index": 0, "role": string, "en": string, "ru": string, "tip_ru": string|null}]
        }
        Rules:
        - Detect 2 speakers (names or Worker A/B). Exactly two roles, slots a and b.
        - Split into ordered turns. Each line needs English "en" and Russian "ru".
        - If only one language present, translate the other (UK site English ↔ RU).
        - tip_ru: short tip when useful, else null.
        - Keep technical terms accurate (MCB, trunking, consumer unit, RJ45, etc.).
        """

        let raw = try await generateJSON(
            userText: String(trimmed.prefix(6000)),
            system: system,
            timeout: GeminiConfig.lessonTimeout,
            maxTokens: 4096,
            temperature: 0.2,
            skipRateLimit: false
        )

        if let script = parseRoleplayJSON(raw, sourceRaw: trimmed) {
            return script
        }
        if let local = RoleplayParserService.parseLocally(trimmed) {
            return local
        }
        throw RoleplayParseError.noLines
    }

    /// Free-form brief (RU/EN, no Name:) → short Supervisor/Installer dialogue.
    func generateRoleplay(brief: String) async throws -> RoleplayScript {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { throw RoleplayParseError.tooShort }

        let system = """
        You write short construction-site roleplay dialogues for Ireland (electrical / containment / Unistrut / tray).
        The user describes what they need in free RU or EN — NOT a script. Invent a natural dialogue.

        Output ONLY JSON:
        {
          "title_ru": string,
          "scene_ru": string,
          "roles": [{"name": "Supervisor"|"Foreman", "slot": "a"}, {"name": "Installer", "slot": "b"}],
          "lines": [{"index": 0, "role": string, "en": string, "ru": string, "tip_ru": string|null}]
        }

        HARD RULES:
        - 4–8 turns, alternate Supervisor/Foreman and Installer (start with Supervisor/Foreman).
        - EN: conversational A1–A2, short lines (max ~12 words), grammatically correct (B16).
        - Use Ireland site words from the brief when present: tray, basket, lay down, clamp, bolt, Unistrut, containment, zebs, hold, hand, PPE, Safe Pass.
        - Each line: correct EN + natural short RU. tip_ru optional (one site tip) else null.
        - No stage directions. No Name: in "en". Do not invent long lectures.
        - If brief asks for N lines (e.g. «6 реплик»), aim for that count within 4–8.
        """

        let raw = try await generateJSON(
            userText: "Brief (make dialogue):\n\(String(trimmed.prefix(1500)))",
            system: system,
            timeout: GeminiConfig.lessonTimeout,
            maxTokens: 3072,
            temperature: 0.45,
            skipRateLimit: false
        )

        if let script = parseRoleplayJSON(raw, sourceRaw: trimmed) {
            // Clamp to 4–8 when model overshoots.
            if script.lines.count > 8 {
                var clipped = script
                clipped.lines = Array(script.lines.prefix(8))
                return clipped
            }
            return script
        }
        throw RoleplayParseError.gemini("Gemini не собрал диалог — попробуй ещё раз")
    }

    // MARK: - Tutor talk coach (CEFR action-oriented)

    /// System prompt for «Поговорить» site — lives here; UI: TutorTalkView.
    static let coachTalkSystemPrompt = """
    You are a friendly Ireland building-site buddy (foreman vibe), A1–A2.
    Languages: short RU for coaching + clear UK English for the phrase to say.
    Domain: electrical / CCTV / induction / Safe Pass / PPE / containment / tools.
    CEFR: action-oriented, goal-oriented cooperation on site — NOT a grammar lecture.

    HARD RULES:
    - On START / first turn: immediately offer 2–3 site topics AND one concrete line «скажи сейчас: …» (EN + short RU).
    - Never force the learner to invent a topic from scratch.
    - Cycle: hint → learner attempt → (mistakes OK) → soft recast with the correct phrase → ask to repeat → praise → next micro-task.
    - Do NOT dump grammar before speech. Grammar only if they ask or tap «Почему?».
    - Keep coach_ru under ~40 words. One say_now_en per turn.
    - If user said broken EN/RU/surzhyk: recast softly, never shame.
    - If input looks like STT garbage (e.g. "reading my heart" vs target "hard hat"): say briefly in RU «Микрофон сбился — нажми Ещё раз», KEEP the SAME say_now_en. Do NOT invent a new story about hearts/eyes.
    - When userText starts with LEARNER_PASS: celebrate briefly, then either ask one repeat of the same line or give the next micro-task.

    Output ONLY JSON (no markdown):
    {
      "coach_ru": "короткий текст коуча",
      "say_now_en": "exact UK English to practise",
      "say_now_ru": "полный RU перевод say_now_en",
      "topics": ["topic1", "topic2", "topic3"],
      "why_seed": "optional short RU/EN question for Why mode"
    }
    """

    /// Everyday English coach — NO site jargon (Safe Pass / tray / Unistrut / induction).
    static let coachTalkGeneralSystemPrompt = """
    You are a friendly everyday-English buddy for adults (A1–A2), Ireland/UK English.
    Languages: short RU for coaching + clear everyday EN for the phrase to say.
    Domain ONLY: home, food, travel, shopping, feelings, phone, friends, daily routine, weather, office small-talk.
    NEVER use building-site / electrical / Safe Pass / hard hat / cable tray / Unistrut / PPE / induction topics in this mode.

    HARD RULES:
    - On START / first turn: offer 2–3 everyday topics AND one concrete «скажи сейчас: …» (EN + short RU).
    - Never force the learner to invent a topic from scratch.
    - Cycle: hint → attempt → soft recast → repeat → praise → next micro-task.
    - No grammar lecture. Grammar only if they ask «Почему?».
    - coach_ru under ~40 words. One say_now_en per turn.
    - Broken EN/RU: recast softly, never shame.
    - STT garbage: «Микрофон сбился — ещё раз», KEEP the SAME say_now_en.
    - LEARNER_PASS: brief praise, then next everyday micro-task.

    Output ONLY JSON (no markdown):
    {
      "coach_ru": "короткий текст коуча",
      "say_now_en": "exact everyday UK English to practise",
      "say_now_ru": "полный RU перевод say_now_en",
      "topics": ["Home", "Food", "Travel"],
      "why_seed": "optional short question for Why mode"
    }
    """

    func coachTalk(
        history: [(isUser: Bool, text: String)],
        userText: String,
        topicHint: String?,
        contentMode: TutorContentMode = .site
    ) async throws -> TutorCoachReply {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GeminiRequestError.tooShort }

        var transcript = ""
        transcript += "mode=\(contentMode.rawValue)\n"
        if let topicHint, !topicHint.isEmpty {
            transcript += "Preferred topic hint: \(topicHint)\n"
        }
        for turn in history.suffix(8) {
            transcript += turn.isUser ? "Learner: \(turn.text)\n" : "Coach: \(turn.text)\n"
        }
        transcript += "Learner: \(trimmed)"

        let system = contentMode == .general
            ? Self.coachTalkGeneralSystemPrompt
            : Self.coachTalkSystemPrompt

        let raw = try await generateJSON(
            userText: transcript,
            system: system,
            timeout: GeminiConfig.timeout,
            maxTokens: 768,
            temperature: 0.4,
            skipRateLimit: false
        )
        guard let reply = parseCoachTalk(raw) else { throw GeminiRequestError.badJSON }
        return reply
    }

    /// Handwritten worksheet photo → friendly RU feedback (max 3 fixes) + answer key reminder.
    func checkWorksheetPhoto(imageJPEG: Data, topic: String, answerKey: String) async throws -> String {
        let system = """
        You check a handwritten English-on-site worksheet (Ireland, A1–A2).
        Be friendly. Praise effort. Max 3 short correction points in Russian.
        Then list correct answers briefly.
        Output ONLY JSON: {"feedback_ru":"Ок / что поправить (макс 3)\\nПравильные ответы: …"}
        """
        let user = """
        Тема: \(topic)
        Ключ ответов:
        \(answerKey)
        Проверь фото рукописного листа.
        """
        let raw = try await generateJSON(
            userText: user,
            system: system,
            timeout: GeminiConfig.timeout,
            maxTokens: 768,
            temperature: 0.3,
            skipRateLimit: false,
            imageJPEG: imageJPEG
        )
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { throw GeminiRequestError.emptyResponse }
        if let data = t.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let feedback = (obj["feedback_ru"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !feedback.isEmpty {
            return feedback
        }
        // Fallback: strip JSON braces if model returned plain text wrapped oddly
        return t
            .replacingOccurrences(of: #"^\{"feedback_ru"\s*:\s*""#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #""\s*\}\s*$"#, with: "", options: .regularExpression)
    }

    func tutorWhy(question: String) async throws -> TutorWhyAnswer {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { throw GeminiRequestError.tooShort }

        let system = """
        You explain ONE tiny English point for Ireland building-site workers (A1–A2).
        Answer in simple Russian. Max ONE rule. Two short EN site examples + RU gloss.
        One line «на сайте так говорят». No essay. No jargon wall.
        Output ONLY JSON:
        {
          "rule_ru": "...",
          "example1_en": "...",
          "example1_ru": "...",
          "example2_en": "...",
          "example2_ru": "...",
          "site_line_ru": "..."
        }
        """
        let raw = try await generateJSON(
            userText: q,
            system: system,
            timeout: GeminiConfig.timeout,
            maxTokens: 512,
            temperature: 0.25,
            skipRateLimit: false
        )
        guard let a = parseWhy(raw) else { throw GeminiRequestError.badJSON }
        return a
    }

    private func parseCoachTalk(_ raw: String) -> TutorCoachReply? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let coach = ((obj["coach_ru"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sayEN = ((obj["say_now_en"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sayRU = ((obj["say_now_ru"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var topics: [String] = []
        if let t = obj["topics"] as? [String] {
            topics = t.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let why = ((obj["why_seed"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !coach.isEmpty || !sayEN.isEmpty else { return nil }
        return TutorCoachReply(
            coachRU: coach.isEmpty ? "Скажи эту фразу на объекте:" : coach,
            sayNowEN: sayEN,
            sayNowRU: sayRU,
            topics: Array(topics.prefix(3)),
            whySeed: why
        )
    }

    private func parseWhy(_ raw: String) -> TutorWhyAnswer? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func s(_ k: String) -> String {
            ((obj[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rule = s("rule_ru")
        guard !rule.isEmpty else { return nil }
        return TutorWhyAnswer(
            ruleRU: rule,
            example1EN: s("example1_en"),
            example1RU: s("example1_ru"),
            example2EN: s("example2_en"),
            example2RU: s("example2_ru"),
            siteLineRU: s("site_line_ru")
        )
    }

    /// NodeForge 1.2 — surzhyk / translit / mixed → correct EN + RU mirror (strict JSON).
    func tutorReply(history: [SiteTutorTurn], userText: String) async throws -> SiteTutorReply {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else { throw GeminiRequestError.tooShort }

        let system = """
        You are an English coach for Ireland building sites (UK English): electricians, CCTV, installers OK.
        Level A1–A2, task-based: one useful phrase for a job on site — not a grammar lecture.
        Teaching cycle (follow in every reply, keep tip_ru short):
        1) Смысл RU  2) EN форма  3) Слушать (EN only)  4) Сказать  5) Короткий feedback  6) Предложить «в тренажёр» for spaced repeat.
        User may type or speak Russian, surzhyk, translit, broken EN, or ask about phrasals ("over", "phrasal take").
        Map intent to correct written English. Broken EN is NOT the gold standard — fix it.
        If ask is a general phrasal (over / take / get / put): give GENERAL meanings first; still add Ireland site examples where natural.
        If ask is site surzhyk (e.g. tray / basket / terminate): fix to proper EN + RU.
        Output ONLY this JSON — no markdown, no fences:
        {
          "heard_or_input": "...",
          "en": "correct UK English sentence for the site task",
          "ru": "полный перевод этого предложения на русский (не lemma)",
          "tip_ru": "1 строка: как потренировать / что сказать на объекте",
          "phrasals": [{
            "en": "phrasal or sense label",
            "ru": "lemma / sense RU",
            "example_en": "general example sentence",
            "example_ru": "полный RU перевод example_en",
            "site_examples": ["Ireland site example 1", "site example 2"],
            "site_examples_ru": ["полный RU 1", "полный RU 2"],
            "say_it": "one short line to practise",
            "say_it_ru": "полный RU перевод say_it"
          }],
          "say_it": "one phrase for the speaking trainer",
          "say_it_ru": "полный RU перевод say_it"
        }
        Rules:
        - For "over" / "phrasal X" requests: fill phrasals with 2–5 senses; each needs site_examples (2–3) + matching site_examples_ru + say_it + say_it_ru.
        - For free surzhyk: en/ru/tip/say_it required; phrasals optional; ru and say_it_ru must be full sentences, not a single verb gloss.
        - say_it never empty when en is set.
        - Never lecture grammar; keep tip_ru under 20 words.
        """

        var transcript = ""
        for turn in history.suffix(6) {
            if turn.role == .user {
                transcript += "User: \(turn.text)\n"
            } else if let r = turn.reply {
                transcript += "Tutor EN: \(r.en) | RU: \(r.ru)\n"
            } else {
                transcript += "Tutor: \(turn.text)\n"
            }
        }
        transcript += "User: \(trimmed)"

        let raw = try await generateJSON(
            userText: transcript,
            system: system,
            timeout: GeminiConfig.timeout,
            maxTokens: 1536,
            temperature: 0.35,
            skipRateLimit: false
        )

        guard let reply = parseTutorReply(raw, fallbackInput: trimmed) else {
            throw GeminiRequestError.badJSON
        }
        return reply
    }

    // MARK: - HTTP

    static func sanitizedAPIKey() -> String {
        var key = KeychainStore.loadGeminiAPIKey()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if (key.hasPrefix("\"") && key.hasSuffix("\"")) || (key.hasPrefix("'") && key.hasSuffix("'")) {
            key = String(key.dropFirst().dropLast())
        }
        if key.lowercased().hasPrefix("bearer ") {
            key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return key
    }

    /// Site photo: FIRST identify object/document, THEN OCR/translate (Ireland construction).
    func translatePhoto(
        imageJPEG: Data,
        caption: String,
        settings: AppSettings
    ) async throws -> TranslationResult {
        let note = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = """
        You identify Ireland construction-site photos (tools, PPE, labels, signs, forms).
        ALWAYS identify WHAT is in the photo first (name_en / name_ru / kind).
        Then OCR any visible text and translate. If blurry/empty: unclear=true, short RU message in summary_ru.
        Output ONLY JSON matching the user schema. No markdown.
        """
        let user = """
        Фото с объекта Ireland (инструмент / бирка / каска / лист / щит / форма).
        \(note.isEmpty ? "" : "Подпись пользователя: \(note)\n")
        Сначала ОПРЕДЕЛИ объект, потом OCR/перевод.
        Ответ ТОЛЬКО JSON:
        {
          "name_en":"drill / Safe Pass card / MEWP checklist / cable tray / …",
          "name_ru":"…",
          "kind":"tool|part|label|document|sign|other",
          "confidence":"high|medium|low",
          "ocr_text":"текст как на объекте или пусто",
          "translation_ru":"перевод OCR или пусто",
          "translation_en":"EN зеркало OCR или пусто",
          "document_guess":"если kind=document — иначе пусто",
          "summary_ru":"1–2 предложения что это; если блюр — Не разобрал, сними ближе",
          "key_fields":["поле1","поле2"],
          "site_tip_en":"одна фраза как сказать на объекте",
          "site_tip_ru":"перевод tip",
          "unclear":false,
          "en":"то же что name_en или site_tip_en",
          "ru":"то же что name_ru",
          "tip_ru":"site_tip_ru",
          "tag":"tools"
        }
        """
        let raw = try await generateJSON(
            userText: user,
            system: system,
            timeout: GeminiConfig.timeout,
            maxTokens: 1024,
            temperature: 0.2,
            skipRateLimit: false,
            imageJPEG: imageJPEG
        )
        guard let photo = parsePhotoIdentify(raw) else {
            throw GeminiRequestError.badJSON
        }
        if photo.unclear
            && photo.nameEN.isEmpty
            && photo.ocrText.isEmpty {
            return TranslationResult(
                sourceText: "",
                translatedText: "",
                sourceIsRussian: false,
                matched: false,
                tipRu: photo.summaryRU.isEmpty ? "Не разобрал, сними ближе" : photo.summaryRU,
                tag: .other,
                fallbackSpokenRU: nil,
                viaGemini: true,
                geminiErrorRU: photo.summaryRU.isEmpty ? "Не разобрал, сними ближе" : photo.summaryRU,
                photo: photo
            )
        }
        let enOut = photo.translationEN.isEmpty ? (photo.siteTipEN.isEmpty ? photo.nameEN : photo.siteTipEN) : photo.translationEN
        let ruOut = photo.translationRU.isEmpty ? (photo.siteTipRU.isEmpty ? photo.nameRU : photo.siteTipRU) : photo.translationRU
        let source = photo.ocrText.isEmpty ? photo.nameEN : photo.ocrText
        let sourceIsRU = isMostlyRussian(source)
        return TranslationResult(
            sourceText: sourceIsRU ? (photo.ocrText.isEmpty ? photo.nameRU : photo.ocrText) : source,
            translatedText: sourceIsRU ? enOut : ruOut,
            sourceIsRussian: sourceIsRU,
            matched: true,
            tipRu: photo.siteTipRU.isEmpty ? photo.summaryRU : photo.siteTipRU,
            tag: .other,
            fallbackSpokenRU: nil,
            viaGemini: true,
            photo: photo
        )
    }

    private func parsePhotoIdentify(_ raw: String) -> PhotoIdentifyResult? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func str(_ key: String) -> String {
            if let s = obj[key] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let n = obj[key] as? NSNumber { return n.stringValue }
            return ""
        }
        let fields: [String]
        if let arr = obj["key_fields"] as? [String] {
            fields = arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else {
            fields = []
        }
        let unclear: Bool = {
            if let b = obj["unclear"] as? Bool { return b }
            if let n = obj["unclear"] as? NSNumber { return n.boolValue }
            return false
        }()
        let nameEN = str("name_en")
        let nameRU = str("name_ru")
        // Tolerate partial answers: need at least a name or OCR or summary
        if nameEN.isEmpty && nameRU.isEmpty && str("ocr_text").isEmpty && str("summary_ru").isEmpty && str("en").isEmpty {
            return nil
        }
        return PhotoIdentifyResult(
            nameEN: nameEN.isEmpty ? str("en") : nameEN,
            nameRU: nameRU.isEmpty ? str("ru") : nameRU,
            kind: str("kind").isEmpty ? "other" : str("kind"),
            confidence: str("confidence").isEmpty ? "medium" : str("confidence"),
            ocrText: str("ocr_text"),
            translationRU: str("translation_ru").isEmpty ? str("ru") : str("translation_ru"),
            translationEN: str("translation_en").isEmpty ? str("en") : str("translation_en"),
            documentGuess: str("document_guess"),
            summaryRU: str("summary_ru"),
            keyFields: fields,
            siteTipEN: str("site_tip_en").isEmpty ? str("say_it") : str("site_tip_en"),
            siteTipRU: str("site_tip_ru").isEmpty ? str("tip_ru") : str("site_tip_ru"),
            unclear: unclear
        )
    }

    private func extractOCR(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocr = obj["ocr_text"] as? String else { return nil }
        let t = ocr.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func generateJSON(
        userText: String,
        system: String,
        timeout: TimeInterval,
        maxTokens: Int,
        temperature: Double,
        skipRateLimit: Bool,
        imageJPEG: Data? = nil
    ) async throws -> String {
        let apiKey = Self.sanitizedAPIKey()
        guard !apiKey.isEmpty else {
            print("[gemini] error=noAPIKey")
            throw GeminiRequestError.noAPIKey
        }

        if !skipRateLimit {
            let now = Date()
            let gap = now.timeIntervalSince(lastRequestAt)
            guard gap >= minInterval else {
                print("[gemini] error=rateLimited gap=\(String(format: "%.1f", gap))s")
                throw GeminiRequestError.rateLimited
            }
            lastRequestAt = now
        }

        // Unique models in fallback order (primary first).
        var models: [String] = []
        for id in [GeminiConfig.model] + GeminiConfig.modelFallbackChain where !models.contains(id) {
            models.append(id)
        }

        var lastHTTP: GeminiRequestError?

        for (index, modelId) in models.enumerated() {
            do {
                let text = try await postGenerateContent(
                    modelId: modelId,
                    apiKey: apiKey,
                    userText: userText,
                    system: system,
                    timeout: timeout,
                    maxTokens: maxTokens,
                    temperature: temperature,
                    imageJPEG: imageJPEG
                )
                GeminiConfig.lastUsedModel = modelId
                return text
            } catch let e as GeminiRequestError {
                if case .httpStatus(404, _) = e, index + 1 < models.count {
                    print("[gemini] 404 model=\(modelId) → fallback \(models[index + 1])")
                    lastHTTP = e
                    continue
                }
                throw e
            }
        }

        throw lastHTTP ?? GeminiRequestError.httpStatus(404, "модель недоступна")
    }

    private func postGenerateContent(
        modelId: String,
        apiKey: String,
        userText: String,
        system: String,
        timeout: TimeInterval,
        maxTokens: Int,
        temperature: Double,
        imageJPEG: Data? = nil
    ) async throws -> String {
        guard let url = URL(string: GeminiConfig.endpoint(for: modelId)) else {
            throw GeminiRequestError.network("bad URL")
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        var parts: [[String: Any]] = [["text": userText]]
        if let imageJPEG, !imageJPEG.isEmpty {
            parts.append([
                "inline_data": [
                    "mime_type": "image/jpeg",
                    "data": imageJPEG.base64EncodedString(),
                ],
            ])
        }

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": system]],
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": parts,
                ],
            ],
            "generationConfig": [
                "temperature": temperature,
                "maxOutputTokens": maxTokens,
                "responseMimeType": "application/json",
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[gemini] request start model=\(modelId) timeout=\(Int(timeout))s")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            let ns = error as NSError
            print("[gemini] error=network code=\(ns.code) \(error.localizedDescription)")
            throw GeminiRequestError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            print("[gemini] error=emptyResponse (no HTTP)")
            throw GeminiRequestError.emptyResponse
        }

        print("[gemini] status=\(http.statusCode) bytes=\(data.count) model=\(modelId)")

        guard (200...299).contains(http.statusCode) else {
            let detail = Self.extractGoogleErrorMessage(from: data)
            print("[gemini] error=http \(http.statusCode) \(detail)")
            throw GeminiRequestError.httpStatus(http.statusCode, String(detail.prefix(80)))
        }

        guard let text = extractText(from: data) else {
            if let block = extractBlockReason(from: data) {
                print("[gemini] error=blocked \(block)")
                throw GeminiRequestError.blocked(block)
            }
            print("[gemini] error=emptyResponse")
            throw GeminiRequestError.emptyResponse
        }
        return text
    }

    private static func extractGoogleErrorMessage(from data: Data) -> String {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let err = obj["error"] as? [String: Any]
        else { return "" }
        let message = (err["message"] as? String) ?? ""
        let status = (err["status"] as? String) ?? ""
        if message.localizedCaseInsensitiveContains("API key")
            || message.localizedCaseInsensitiveContains("api_key")
            || status == "UNAUTHENTICATED"
            || status == "PERMISSION_DENIED" {
            return "плохой ключ"
        }
        // Strip any accidental key-looking tokens
        return message
            .replacingOccurrences(of: #"AIza[0-9A-Za-z_-]+"#, with: "[key]", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractBlockReason(from data: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = obj["candidates"] as? [[String: Any]],
            let first = candidates.first
        else { return nil }
        if let reason = first["finishReason"] as? String,
           reason == "SAFETY" || reason == "BLOCKLIST" || reason == "PROHIBITED_CONTENT" {
            return "Gemini: safety block"
        }
        if let pf = obj["promptFeedback"] as? [String: Any],
           let br = pf["blockReason"] as? String {
            return "Gemini: \(br)"
        }
        return nil
    }

    private func extractText(from data: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = obj["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { return nil }

        let texts = parts.compactMap { $0["text"] as? String }
        let joined = texts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        return stripMarkdownFence(joined)
    }

    private func stripMarkdownFence(_ text: String) -> String {
        var t = text
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "```json", with: "")
            t = t.replacingOccurrences(of: "```", with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseOffTopic(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? String,
              err == "off_topic" else { return nil }
        return (obj["message_ru"] as? String) ?? ""
    }

    private func parseLesson(_ raw: String) -> Lesson? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Lesson.self, from: data)
    }

    private func decodeLooseJSON(_ raw: String) -> [String: Any]? {
        let cleaned = stripMarkdownFence(raw)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Tolerant parse: tip_ru / tag / say_it may be missing or null (was a silent fail before).
    private func parseRemember(_ raw: String) -> RememberAnalysis? {
        guard let obj = decodeLooseJSON(raw) else { return nil }

        func str(_ key: String) -> String? {
            if let s = obj[key] as? String { return s }
            if obj[key] is NSNull { return nil }
            if let n = obj[key] as? NSNumber { return n.stringValue }
            return nil
        }

        let en = (str("en") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ru = (str("ru") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !en.isEmpty, !ru.isEmpty else { return nil }

        var tip = (str("tip_ru") ?? str("tipRu") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if tip.count > 120 { tip = String(tip.prefix(117)) + "…" }

        let tagRaw = (str("tag") ?? "other").lowercased()
        let tag = LibraryTag(rawValue: tagRaw) ?? .other
        let say = (str("say_it") ?? str("sayIt") ?? en)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let note = str("colloquial_note_ru") ?? str("colloquialNoteRu")
        let noteTrim = note?.trimmingCharacters(in: .whitespacesAndNewlines)

        return RememberAnalysis(
            en: en,
            ru: ru,
            tipRu: tip,
            tag: tag,
            sayIt: say.isEmpty ? en : say,
            colloquialNoteRu: (noteTrim?.isEmpty == false) ? noteTrim : nil
        )
    }

    private func isMostlyRussian(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return PhraseBank.containsCyrillic(text) }
        let cyr = letters.filter { (0x0400...0x04FF).contains($0.value) }.count
        return cyr * 2 >= letters.count
    }

    private func parseRoleplayJSON(_ raw: String, sourceRaw: String) -> RoleplayScript? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func str(_ key: String) -> String? {
            if let s = obj[key] as? String { return s }
            return nil
        }

        let title = (str("title_ru") ?? str("titleRu") ?? "Диалог").trimmingCharacters(in: .whitespacesAndNewlines)
        let scene = (str("scene_ru") ?? str("sceneRu") ?? "Импортированный диалог")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let rolesArr = obj["roles"] as? [[String: Any]], rolesArr.count >= 1 else { return nil }
        var roles: [RoleplayRole] = []
        for (i, r) in rolesArr.prefix(2).enumerated() {
            let name = ((r["name"] as? String) ?? "Worker \(i == 0 ? "A" : "B")")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let slotRaw = ((r["slot"] as? String) ?? (i == 0 ? "a" : "b")).lowercased()
            let slot = slotRaw == "b" ? "b" : "a"
            guard !name.isEmpty else { continue }
            roles.append(RoleplayRole(name: name, slot: slot))
        }
        if roles.count == 1 {
            roles.append(RoleplayRole(name: "Worker B", slot: "b"))
        }
        guard roles.count == 2 else { return nil }

        guard let linesArr = obj["lines"] as? [[String: Any]], !linesArr.isEmpty else { return nil }
        var lines: [RoleplayLine] = []
        for (idx, L) in linesArr.enumerated() {
            let role = ((L["role"] as? String) ?? roles[idx % 2].name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let en = ((L["en"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ru = ((L["ru"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !en.isEmpty else { continue }
            let tip = (L["tip_ru"] as? String) ?? (L["tipRu"] as? String)
            let tipTrim = tip?.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(RoleplayLine(
                index: idx,
                role: role.isEmpty ? roles[idx % 2].name : role,
                en: en,
                ru: ru.isEmpty ? "(перевод позже)" : ru,
                tipRu: (tipTrim?.isEmpty == false) ? tipTrim : nil
            ))
        }
        guard lines.count >= 2 else { return nil }

        return RoleplayScript(
            id: "rp-\(Int(Date().timeIntervalSince1970))",
            titleRu: title.isEmpty ? "Диалог" : title,
            sceneRu: scene,
            roles: roles,
            lines: lines,
            sourceRaw: String(sourceRaw.prefix(2000)),
            createdAt: Date()
        )
    }

    private func parseTutorReply(_ raw: String, fallbackInput: String) -> SiteTutorReply? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func str(_ key: String) -> String? {
            if let s = obj[key] as? String { return s }
            if obj[key] is NSNull { return nil }
            return nil
        }

        // New schema (1.2)
        var en = (str("en") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var ru = (str("ru") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var tip = (str("tip_ru") ?? str("tipRu") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var sayIt = (str("say_it") ?? str("sayIt") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var sayItRu = (str("say_it_ru") ?? str("sayItRu") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = (str("heard_or_input") ?? str("heardOrInput") ?? fallbackInput)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Legacy schema fallback (reply_ru / say_en)
        if en.isEmpty {
            en = (str("say_en") ?? str("sayEn") ?? str("correct_en") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ru.isEmpty {
            ru = (str("reply_ru") ?? str("replyRu") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if tip.isEmpty, let legacyTip = str("tip_ru") ?? str("tipRu") {
            tip = legacyTip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if sayIt.isEmpty { sayIt = en }
        if sayItRu.isEmpty { sayItRu = ru }

        guard !en.isEmpty || !ru.isEmpty else { return nil }
        if en.isEmpty { en = sayIt }
        if sayIt.isEmpty { sayIt = en }
        if ru.isEmpty { ru = en }
        if sayItRu.isEmpty { sayItRu = ru }

        var phrasals: [SiteTutorPhrasal] = []
        if let arr = obj["phrasals"] as? [[String: Any]] {
            for p in arr.prefix(6) {
                let pe = ((p["en"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let pr = ((p["ru"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let ex = ((p["example_en"] as? String) ?? (p["exampleEn"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let exRu = ((p["example_ru"] as? String) ?? (p["exampleRu"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pe.isEmpty else { continue }
                var sites: [String] = []
                if let sa = p["site_examples"] as? [String] {
                    sites = sa.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                } else if let sa = p["siteExamples"] as? [String] {
                    sites = sa.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                }
                var sitesRu: [String] = []
                if let sa = p["site_examples_ru"] as? [String] {
                    sitesRu = sa.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                } else if let sa = p["siteExamplesRu"] as? [String] {
                    sitesRu = sa.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                }
                if sites.isEmpty, !ex.isEmpty { sites = [ex] }
                let say = ((p["say_it"] as? String) ?? (p["sayIt"] as? String) ?? ex)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let sayRu = ((p["say_it_ru"] as? String) ?? (p["sayItRu"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                phrasals.append(SiteTutorPhrasal(
                    en: pe,
                    ru: pr,
                    exampleEn: ex,
                    exampleRu: exRu,
                    siteExamples: Array(sites.prefix(3)),
                    siteExamplesRu: Array(sitesRu.prefix(3)),
                    sayIt: say.isEmpty ? pe : say,
                    sayItRu: sayRu
                ))
            }
        }

        return SiteTutorReply(
            heardOrInput: heard.isEmpty ? fallbackInput : heard,
            en: en,
            ru: ru,
            tipRu: tip,
            phrasals: phrasals,
            sayIt: sayIt,
            sayItRu: sayItRu
        )
    }
}

struct TutorCoachReply: Equatable {
    let coachRU: String
    let sayNowEN: String
    let sayNowRU: String
    let topics: [String]
    let whySeed: String
}

struct TutorWhyAnswer: Equatable {
    let ruleRU: String
    let example1EN: String
    let example1RU: String
    let example2EN: String
    let example2RU: String
    let siteLineRU: String
}

struct SiteTutorPhrasal: Identifiable, Equatable, Hashable {
    var id: String { "\(en)|\(ru)|\(exampleEn)|\(sayIt)" }
    let en: String
    let ru: String
    let exampleEn: String
    let exampleRu: String
    let siteExamples: [String]
    let siteExamplesRu: [String]
    let sayIt: String
    let sayItRu: String

    /// EN+RU pairs for site examples (RU = full sentence when provided).
    var siteExamplePairs: [(en: String, ru: String)] {
        siteExamples.enumerated().map { i, enLine in
            let ruLine: String
            if siteExamplesRu.indices.contains(i), !siteExamplesRu[i].isEmpty {
                ruLine = siteExamplesRu[i]
            } else {
                ruLine = sentenceRu(forExample: enLine)
            }
            return (en: enLine, ru: ruLine)
        }
    }

    /// Prefer full sentence RU; never return empty if lemma `ru` exists.
    func sentenceRu(forExample example: String) -> String {
        if example == exampleEn, !exampleRu.isEmpty { return exampleRu }
        if example == sayIt, !sayItRu.isEmpty { return sayItRu }
        if let idx = siteExamples.firstIndex(of: example),
           siteExamplesRu.indices.contains(idx),
           !siteExamplesRu[idx].isEmpty {
            return siteExamplesRu[idx]
        }
        // Heuristic: lemma-only gloss is short; still show it under the line rather than blank.
        if !ru.isEmpty { return ru }
        return "—"
    }
}

struct SiteTutorReply: Equatable, Hashable {
    let heardOrInput: String
    let en: String
    let ru: String
    let tipRu: String
    let phrasals: [SiteTutorPhrasal]
    let sayIt: String
    let sayItRu: String
}

struct SiteTutorTurn: Identifiable, Equatable {
    enum Role: String { case user, tutor }
    let id: UUID
    let role: Role
    let text: String
    let reply: SiteTutorReply?

    init(id: UUID = UUID(), role: Role, text: String, reply: SiteTutorReply? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.reply = reply
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
