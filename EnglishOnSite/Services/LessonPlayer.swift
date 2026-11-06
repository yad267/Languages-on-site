import Foundation
import Observation

@Observable
@MainActor
final class LessonPlayer {
    enum Mode {
        case lesson
        case sayToday
        case practiceFeedback
    }

    enum SpeakingLanguage {
        case en, ru

        var site: SiteVoiceLang {
            switch self {
            case .en: return .en
            case .ru: return .ru
            }
        }
    }

    private(set) var lesson: Lesson?
    private(set) var currentIndex: Int = 0
    private(set) var isPlaying: Bool = false
    private(set) var isPaused: Bool = false
    private(set) var speakingLanguage: SpeakingLanguage = .en
    private(set) var statusText: String = "Готов"
    private(set) var mode: Mode = .lesson
    private(set) var practiceMessage: String?
    /// Shown when ElevenLabs falls back to AVSpeech.
    private(set) var voiceNote: String = ""

    private var settings: AppSettings
    private var isRepeating: Bool = false
    private var suppressAdvance: Bool = false
    private(set) var sayTodayIndex: Int = 0
    private var feedbackQueue: [String] = []
    private var feedbackCursor: Int = 0
    private var speakTask: Task<Void, Never>?
    private let tts = ElevenLabsTTS.shared

    var currentLine: LessonLine? {
        guard mode == .lesson || mode == .practiceFeedback else { return nil }
        guard let lesson, lesson.lines.indices.contains(currentIndex) else { return nil }
        return lesson.lines[currentIndex]
    }

    var currentSayToday: SayTodayPhrase? {
        guard mode == .sayToday, let lesson else { return nil }
        guard lesson.sayToday.indices.contains(sayTodayIndex) else { return nil }
        return lesson.sayToday[sayTodayIndex]
    }

    var displayEN: String {
        switch mode {
        case .sayToday: return currentSayToday?.en ?? "—"
        default: return currentLine?.en ?? "—"
        }
    }

    var displayRU: String {
        switch mode {
        case .sayToday: return currentSayToday?.ru ?? "—"
        default: return currentLine?.ru ?? "—"
        }
    }

    var progressText: String {
        guard let lesson else { return "0 / 0" }
        switch mode {
        case .sayToday:
            return "\(min(sayTodayIndex + 1, lesson.sayToday.count)) / \(lesson.sayToday.count)"
        default:
            return "\(min(currentIndex + 1, lesson.lines.count)) / \(lesson.lines.count)"
        }
    }

    var progress: Double {
        guard let lesson else { return 0 }
        switch mode {
        case .sayToday:
            guard !lesson.sayToday.isEmpty else { return 0 }
            return Double(sayTodayIndex) / Double(max(lesson.sayToday.count, 1))
        default:
            guard !lesson.lines.isEmpty else { return 0 }
            return Double(currentIndex) / Double(max(lesson.lines.count, 1))
        }
    }

    var canPractice: Bool {
        mode == .lesson && (currentLine?.isPractice == true)
    }

    /// Manual «Назад» — disabled on first dialogue line.
    var canSkipBack: Bool {
        switch mode {
        case .sayToday:
            return true
        case .lesson, .practiceFeedback:
            return currentIndex > 0
        }
    }

    /// Last dialogue line (before «Скажи сегодня»).
    var isOnLastDialogueLine: Bool {
        guard mode == .lesson || mode == .practiceFeedback, let lesson else { return false }
        return currentIndex >= max(lesson.lines.count - 1, 0)
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    func updateSettings(_ settings: AppSettings) {
        self.settings = settings
    }

    func load(_ lesson: Lesson) {
        hardStopSpeaking()
        self.lesson = lesson
        currentIndex = 0
        sayTodayIndex = 0
        speakingLanguage = .en
        mode = .lesson
        practiceMessage = nil
        statusText = "Готов"
        voiceNote = ""
        isPlaying = false
        isPaused = false
    }

    func togglePlayPause() {
        if isPlaying && !isPaused {
            pause()
        } else if isPaused {
            resume()
        } else {
            play()
        }
    }

    func play() {
        guard lesson != nil else { return }
        guard configureSession() else { return }

        if isPaused {
            resume()
            return
        }

        isPlaying = true
        isPaused = false
        statusText = mode == .sayToday ? "Повтори сегодня" : "Играет"
        speakCurrentSegment()
    }

    func pause() {
        guard isPlaying else { return }
        tts.pause()
        isPaused = true
        statusText = "Пауза"
    }

    func resume() {
        guard lesson != nil else { return }
        guard configureSession() else { return }

        if tts.isPausedPlayback, tts.resumePlayback() {
            isPaused = false
            isPlaying = true
            statusText = "Играет"
            return
        }

        isPaused = false
        isPlaying = true
        statusText = "Играет"
        speakCurrentSegment()
    }

    func stop() {
        hardStopSpeaking()
        isPlaying = false
        isPaused = false
        isRepeating = false
        speakingLanguage = .en
        if mode == .practiceFeedback {
            mode = .lesson
            practiceMessage = nil
            feedbackQueue = []
        }
        statusText = "Стоп"
    }

    /// «Дальше»: next text only — never auto-speak.
    func skipForward() {
        hardStopSpeaking()
        isPlaying = false
        isPaused = false
        isRepeating = false
        speakingLanguage = .en

        switch mode {
        case .sayToday:
            guard let lesson else { return }
            if sayTodayIndex + 1 < lesson.sayToday.count {
                sayTodayIndex += 1
                statusText = "Готов"
            } else {
                finishSayToday()
            }
        case .lesson, .practiceFeedback:
            mode = .lesson
            practiceMessage = nil
            guard let lesson else { return }
            if currentIndex + 1 < lesson.lines.count {
                currentIndex += 1
                statusText = "Готов"
            } else if !lesson.sayToday.isEmpty {
                // End of dialogue → «Скажи сегодня» block, silent.
                mode = .sayToday
                sayTodayIndex = 0
                statusText = "Скажи сегодня"
            } else {
                finishLesson()
            }
        }
    }

    /// «Назад»: previous text only — never auto-speak.
    func skipBack() {
        hardStopSpeaking()
        isPlaying = false
        isPaused = false
        isRepeating = false
        speakingLanguage = .en
        practiceMessage = nil

        switch mode {
        case .sayToday:
            if sayTodayIndex > 0 {
                sayTodayIndex -= 1
                statusText = "Готов"
            } else if let lesson, !lesson.lines.isEmpty {
                mode = .lesson
                currentIndex = max(lesson.lines.count - 1, 0)
                statusText = "Готов"
            }
        case .lesson, .practiceFeedback:
            mode = .lesson
            if currentIndex > 0 {
                currentIndex -= 1
                statusText = "Готов"
            }
        }
    }

    func repeatCurrentPhrase() {
        guard lesson != nil else { return }
        guard configureSession() else { return }
        hardStopSpeaking()
        isRepeating = true
        speakingLanguage = .en
        isPaused = false
        isPlaying = true
        statusText = "Повтор"
        if mode == .practiceFeedback {
            mode = .lesson
            practiceMessage = nil
        }
        speakCurrentSegment()
    }

    /// Enter say_today block without autoplay (end of lesson / explicit).
    func startSayToday() {
        guard let lesson, !lesson.sayToday.isEmpty else { return }
        hardStopSpeaking()
        mode = .sayToday
        sayTodayIndex = 0
        speakingLanguage = .en
        isRepeating = false
        practiceMessage = nil
        isPaused = false
        isPlaying = false
        statusText = "Скажи сегодня"
    }

    func exitSayToday() {
        hardStopSpeaking()
        mode = .lesson
        speakingLanguage = .en
        isPlaying = false
        isPaused = false
        statusText = "Готов"
    }

    func runPracticeFlow() {
        guard canPractice, let line = currentLine else { return }
        hardStopSpeaking()
        isPlaying = false
        isPaused = false
        mode = .practiceFeedback
        statusText = "Слушаю…"
        practiceMessage = "Говори 3 секунды…"

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard self.mode == .practiceFeedback else { return }
            CommandFeedback.acknowledged()
            let tip = line.tipRu.map { " \($0)" } ?? ""
            let coach = "Ок. На объекте так и говорят.\(tip) Повтори ещё раз."
            self.practiceMessage = coach
            self.statusText = "Разбор"
            self.feedbackQueue = [coach, line.en]
            self.feedbackCursor = 0
            self.isPlaying = true
            guard self.configureSession() else { return }
            self.speakFeedbackStep()
        }
    }

    func handle(command: VoiceCommandAction) {
        CommandFeedback.acknowledged()
        switch command {
        case .stop, .pause:
            pause()
        case .resume:
            // Voice «дальше» = next phrase (silent). If paused mid-line → resume TTS.
            if isPaused {
                resume()
            } else {
                skipForward()
            }
        case .repeatLast:
            repeatCurrentPhrase()
        case .translate, .remember:
            pause()
        case .newLesson:
            break
        }
    }

    private func configureSession() -> Bool {
        do {
            try AudioSessionManager.configureForLesson()
            return true
        } catch {
            statusText = "Ошибка аудиосессии"
            return false
        }
    }

    private func hardStopSpeaking() {
        suppressAdvance = true
        speakTask?.cancel()
        speakTask = nil
        tts.stop()
    }

    private func speakCurrentSegment() {
        let textEN: String
        let textRU: String
        let role: String
        let lineId: String
        switch mode {
        case .sayToday:
            guard let phrase = currentSayToday else {
                finishSayToday()
                return
            }
            textEN = phrase.en
            textRU = phrase.ru
            role = "say_today"
            lineId = phrase.id
        case .lesson, .practiceFeedback:
            guard let line = currentLine else {
                finishLesson()
                return
            }
            textEN = line.en
            textRU = line.ru
            role = line.role
            lineId = line.id
        }

        // Dialogue / say_today: EN only, voice by role (supervisor vs worker).
        speakingLanguage = .en
        let text = textEN
        let voiceId: String = {
            guard let lesson else { return ElevenLabsConfig.voiceIdEnWorker }
            if mode == .sayToday { return ElevenLabsConfig.voiceIdEnWorker }
            return lesson.enVoiceId(for: role, settings: settings)
        }()
        let sync = EosTTSSyncContext(
            lessonId: lesson?.id ?? "",
            lineId: lineId,
            role: role,
            textEN: textEN,
            textRU: textRU,
            contentVersion: LessonStore.shared.contentVersion
        )
        suppressAdvance = false
        speakTask = Task { @MainActor in
            await self.tts.speak(
                text: text,
                voiceId: voiceId,
                lang: .en,
                settings: self.settings,
                sync: sync
            )
            if Task.isCancelled || self.suppressAdvance { return }
            self.applyVoiceNote()
            if self.isPaused { return }
            self.advanceAfterUtterance()
        }
    }

    private func speakFeedbackStep() {
        guard feedbackQueue.indices.contains(feedbackCursor) else {
            mode = .lesson
            practiceMessage = nil
            isPlaying = false
            statusText = "Готов"
            return
        }
        let text = feedbackQueue[feedbackCursor]
        let lang: SiteVoiceLang = feedbackCursor == 0 ? .ru : .en
        suppressAdvance = false
        speakTask = Task { @MainActor in
            await self.tts.speak(text: text, lang: lang, settings: self.settings)
            if Task.isCancelled || self.suppressAdvance { return }
            self.applyVoiceNote()
            if self.isPaused { return }
            self.advanceAfterUtterance()
        }
    }

    private func applyVoiceNote() {
        voiceNote = tts.lastStatusRU
    }

    private static let gapFeedbackSteps: TimeInterval = 0.50

    /// After TTS: EN→RU of the *same* line only; never auto-advance index / next line.
    private func advanceAfterUtterance() {
        if suppressAdvance || isPaused { return }

        if mode == .practiceFeedback {
            feedbackCursor += 1
            if feedbackQueue.indices.contains(feedbackCursor) {
                scheduleNextSpeak(after: Self.gapFeedbackSteps) {
                    self.speakFeedbackStep()
                }
            } else {
                mode = .lesson
                practiceMessage = nil
                isPlaying = false
                statusText = "Готов"
            }
            return
        }

        // Speak EN only — RU stays on screen as text (no RU TTS).
        speakingLanguage = .en
        isRepeating = false
        isPlaying = false
        isPaused = false
        statusText = "Готов"
    }

    /// Sleep then continue; cancelled by pause/stop/skip via `hardStopSpeaking` / `suppressAdvance`.
    private func scheduleNextSpeak(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        speakTask?.cancel()
        speakTask = Task { @MainActor in
            let ns = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            if Task.isCancelled || self.suppressAdvance || self.isPaused { return }
            work()
        }
    }

    private func finishLesson() {
        isPlaying = false
        isPaused = false
        isRepeating = false
        speakingLanguage = .en
        if let lesson {
            currentIndex = max(lesson.lines.count - 1, 0)
            LessonProgressStore.markCompleted(lesson.id)
        }
        statusText = "Готово"
    }

    private func finishSayToday() {
        isPlaying = false
        isPaused = false
        isRepeating = false
        speakingLanguage = .en
        if let lesson {
            sayTodayIndex = max(lesson.sayToday.count - 1, 0)
            LessonProgressStore.markCompleted(lesson.id)
        }
        statusText = "Сегодня готово"
    }
}
