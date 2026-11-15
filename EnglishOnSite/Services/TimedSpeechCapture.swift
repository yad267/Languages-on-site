import AVFoundation
import Foundation
import Observation
import Speech

/// User-stopped capture: tap Done when finished (min 0.5s, max safety cap).
@Observable
@MainActor
final class TimedSpeechCapture {
    private(set) var isCapturing = false
    /// Elapsed seconds while listening (counts up).
    private(set) var elapsedSeconds = 0
    /// Seconds remaining until auto-stop.
    private(set) var secondsLeft = 0
    private(set) var partialText = ""
    private(set) var errorMessage = ""
    /// True when auto-stopped at max.
    private(set) var hitMaxCap = false

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timerTask: Task<Void, Never>?
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private var startedAt: Date?
    private var maxSeconds = 60
    private var autoFinishWhen: ((String) -> Bool)?
    private var didAutoFinish = false
    /// Debounce: first moment the live PASS predicate held for the current hypothesis.
    private var autoFinishHoldSince: Date?
    private var autoFinishHoldText = ""
    /// Require PASS to stay true this long (unless SFSpeech marks isFinal).
    private let autoFinishHoldSeconds: TimeInterval = 0.65

    /// Start mic + speech recognition; returns when user calls `finish()` / `cancel()` or max reached.
    /// - Parameter contextualStrings: SFSpeech hints (target phrase + site lexemes). Max ~100 used.
    /// - Parameter autoFinishWhen: live PASS → stop mic after hold / isFinal (full phrase only).
    func captureUntilStopped(
        localeId: String,
        maxSeconds: Int,
        contextualStrings: [String] = [],
        autoFinishWhen: ((String) -> Bool)? = nil
    ) async -> String {
        cancel()
        errorMessage = ""
        partialText = ""
        hitMaxCap = false
        didAutoFinish = false
        autoFinishHoldSince = nil
        autoFinishHoldText = ""
        elapsedSeconds = 0
        self.autoFinishWhen = autoFinishWhen
        self.maxSeconds = max(5, min(maxSeconds, 60))
        secondsLeft = self.maxSeconds

        guard await ensureAuth() else { return "" }

        // B15: never cross RU↔EN fallbacks in one pass (was «Ай Don't Hell»).
        let preferred = localeId
        let fallbacks: [String]
        if preferred.lowercased().hasPrefix("ru") {
            fallbacks = [preferred, "ru-RU"]
        } else {
            fallbacks = [preferred, "en-IE", "en-GB", "en-US"]
        }
        var recognizer: SFSpeechRecognizer?
        var usedLocale = preferred
        for id in fallbacks {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable {
                recognizer = r
                usedLocale = id
                break
            }
        }
        guard let recognizer else {
            errorMessage = "Распознавание \(localeId) недоступно"
            return ""
        }
        let isEnglish = usedLocale.lowercased().hasPrefix("en")

        do {
            try AudioSessionManager.configureForRecording()
        } catch {
            errorMessage = "Аудиосессия"
            return ""
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // Do NOT force on-device for EN: on-device often mangles site PPE
        // (hard hat → hot hat / heart). Server path uses contextualStrings better.
        if !isEnglish, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        var rawHints = contextualStrings
        if isEnglish {
            rawHints.append(contentsOf: PhraseSimilarity.siteContextualHints)
        }
        let hints = Self.dedupeHints(rawHints)
        if !hints.isEmpty {
            request.contextualStrings = hints
        }
        recognitionRequest = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            Task { @MainActor in
                guard let self, let result else { return }
                let raw = result.bestTranscription.formattedString
                let heard = isEnglish ? PhraseSimilarity.correctSiteASR(raw) : raw
                self.partialText = heard
                // Live PASS → stop only after full-phrase PASS holds (or isFinal).
                // Prefix matches must not cut mid-utterance.
                self.considerAutoFinish(heard: heard, isFinal: result.isFinal)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            errorMessage = "Микрофон"
            tearDown()
            return ""
        }

        isCapturing = true
        startedAt = Date()

        timerTask = Task { @MainActor in
            while !Task.isCancelled && self.isCapturing {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let start = self.startedAt else { break }
                let elapsed = Date().timeIntervalSince(start)
                self.elapsedSeconds = Int(elapsed)
                self.secondsLeft = max(0, self.maxSeconds - Int(ceil(elapsed)))
                if elapsed >= Double(self.maxSeconds) {
                    self.hitMaxCap = true
                    CommandFeedback.acknowledged()
                    self.resumeWait()
                    break
                }
            }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.waitContinuation = cont
        }

        // Enforce minimum ~0.5s of audio before cutting.
        if let start = startedAt {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed < 0.5 {
                try? await Task.sleep(nanoseconds: UInt64((0.5 - elapsed) * 1_000_000_000))
            }
        }

        let finalText = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        tearDown()
        guard !finalText.isEmpty else { return "" }
        return isEnglish
            ? PhraseSimilarity.correctSiteASR(finalText)
            : finalText
    }

    /// User tapped «Готово» / «Стоп» — end recording.
    func finish() {
        guard isCapturing else { return }
        if let start = startedAt, Date().timeIntervalSince(start) < 0.45 {
            // Too early — ignore tap; UI can show hint
            return
        }
        resumeWait()
    }

    func cancel() {
        timerTask?.cancel()
        timerTask = nil
        resumeWait()
        tearDown()
    }

    /// Legacy fixed-duration API (maps to maxSeconds auto-stop only). Prefer `captureUntilStopped` + `finish()`.
    func capture(seconds: Int, localeId: String) async -> String {
        await captureUntilStopped(localeId: localeId, maxSeconds: seconds)
    }

    private func resumeWait() {
        if let cont = waitContinuation {
            waitContinuation = nil
            cont.resume()
        }
    }

    /// Auto-finish only when the full-phrase predicate is true long enough, or SFSpeech ends the utterance.
    private func considerAutoFinish(heard: String, isFinal: Bool) {
        guard !didAutoFinish, isCapturing, let pred = autoFinishWhen else { return }
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        // Floor so a single clear short phrase can still finish.
        guard elapsed >= 0.35 else { return }

        let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pred(trimmed) else {
            autoFinishHoldSince = nil
            autoFinishHoldText = ""
            return
        }

        let key = trimmed.lowercased()
        if autoFinishHoldText != key {
            autoFinishHoldText = key
            autoFinishHoldSince = Date()
        }

        let held = autoFinishHoldSince.map { Date().timeIntervalSince($0) } ?? 0
        // isFinal = end-of-utterance from Speech; otherwise require stable full PASS.
        guard isFinal || held >= autoFinishHoldSeconds else { return }

        didAutoFinish = true
        autoFinishHoldSince = nil
        autoFinishHoldText = ""
        resumeWait()
    }

    private func tearDown() {
        isCapturing = false
        autoFinishWhen = nil
        autoFinishHoldSince = nil
        autoFinishHoldText = ""
        timerTask?.cancel()
        timerTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        startedAt = nil
        secondsLeft = 0
    }

    private static func dedupeHints(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in raw {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let key = t.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(t)
            if out.count >= 100 { break }
        }
        return out
    }

    private func ensureAuth() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else {
            errorMessage = "Нет доступа к Speech"
            return false
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else {
            errorMessage = "Нужен микрофон"
            return false
        }
        return true
    }
}
