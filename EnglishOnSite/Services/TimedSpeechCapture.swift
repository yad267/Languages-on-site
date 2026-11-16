import AVFoundation
import Foundation
import Observation
import Speech

/// User-stopped capture: tap Done when finished (min 0.5s, max safety cap).
/// Keeps the mic open across SFSpeech utterance boundaries: when Speech emits
/// `isFinal` mid-phrase (silence / clause break), we commit that segment and
/// start a new recognition task instead of ending the take.
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
    /// Tap runs off the main actor — keep the live request in a box for append().
    private let requestBox = RequestBox()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest? {
        didSet { requestBox.request = recognitionRequest }
    }
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var isEnglish = true
    private var contextualHints: [String] = []
    private var timerTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private var startedAt: Date?
    private var maxSeconds = 60
    private var autoFinishWhen: ((String) -> Bool)?
    private var expectedPhrase = ""
    private var didAutoFinish = false
    /// Text from completed Speech utterances (isFinal) in this take.
    private var committedText = ""
    /// Live hypothesis for the current Speech utterance only.
    private var segmentPartial = ""
    /// Debounce: first moment the live PASS predicate held for the current hypothesis.
    private var autoFinishHoldSince: Date?
    private var autoFinishHoldText = ""
    /// Once full PASS is seen, do not clear on brief SFSpeech regressions (trailing-word flicker).
    private var passLatched = false
    /// Best transcript that satisfied full PASS (used if later partials regress).
    private var lastPassText = ""
    /// Brief confirm that full-phrase PASS is stable (stablePassKey ignores raw jitter).
    private let autoFinishHoldSeconds: TimeInterval = 0.12
    private var restartGeneration = 0
    private var interruptionObserver: NSObjectProtocol?

    /// Start mic + speech recognition; returns when user calls `finish()` / `cancel()` or max reached.
    /// - Parameter contextualStrings: SFSpeech hints (target phrase + site lexemes). Max ~100 used.
    /// - Parameter expectedPhrase: target EN — blocks auto-finish until progressive match covers every token (incl. trailing «hard hat»).
    /// - Parameter autoFinishWhen: live PASS on the *combined* transcript → stop after hold.
    func captureUntilStopped(
        localeId: String,
        maxSeconds: Int,
        contextualStrings: [String] = [],
        expectedPhrase: String = "",
        autoFinishWhen: ((String) -> Bool)? = nil
    ) async -> String {
        cancel()
        errorMessage = ""
        partialText = ""
        committedText = ""
        segmentPartial = ""
        hitMaxCap = false
        didAutoFinish = false
        autoFinishHoldSince = nil
        autoFinishHoldText = ""
        passLatched = false
        lastPassText = ""
        elapsedSeconds = 0
        restartGeneration &+= 1
        self.expectedPhrase = expectedPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        self.autoFinishWhen = autoFinishWhen
        self.maxSeconds = max(5, min(maxSeconds, 60))
        secondsLeft = self.maxSeconds

        guard await ensureAuth() else { return "" }

        // Same-language fallbacks only — never cross tongues (was «Ай Don't Hell»).
        let preferred = localeId
        let lower = preferred.lowercased()
        let fallbacks: [String]
        if lower.hasPrefix("ru") {
            fallbacks = [preferred, "ru-RU"]
        } else if lower.hasPrefix("es") {
            fallbacks = [preferred, "es-ES", "es-MX", "es-US"]
        } else if lower.hasPrefix("de") {
            fallbacks = [preferred, "de-DE", "de-AT"]
        } else if lower.hasPrefix("fr") {
            fallbacks = [preferred, "fr-FR", "fr-CA"]
        } else if lower.hasPrefix("pt") {
            fallbacks = [preferred, "pt-PT", "pt-BR"]
        } else if lower.hasPrefix("en") {
            fallbacks = [preferred, "en-IE", "en-GB", "en-US"]
        } else {
            fallbacks = [preferred]
        }
        var picked: SFSpeechRecognizer?
        var usedLocale = preferred
        for id in fallbacks {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable {
                picked = r
                usedLocale = id
                break
            }
        }
        guard let picked else {
            errorMessage = "Распознавание \(localeId) недоступно"
            return ""
        }
        recognizer = picked
        isEnglish = usedLocale.lowercased().hasPrefix("en")

        do {
            try AudioSessionManager.configureForRecording()
        } catch {
            errorMessage = "Аудиосессия"
            log("session configure failed: \(error.localizedDescription)")
            return ""
        }

        var rawHints = contextualStrings
        if isEnglish {
            rawHints.append(contentsOf: PhraseSimilarity.siteContextualHints)
        }
        contextualHints = Self.dedupeHints(rawHints)

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        // Always append to the *current* request so utterance restarts keep working.
        let box = requestBox
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            errorMessage = "Микрофон"
            log("engine start failed: \(error.localizedDescription)")
            tearDown()
            return ""
        }

        isCapturing = true
        startedAt = Date()
        installInterruptionObserver()
        startRecognitionTask(reason: "begin")

        timerTask = Task { @MainActor in
            while !Task.isCancelled && self.isCapturing {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let start = self.startedAt else { break }
                let elapsed = Date().timeIntervalSince(start)
                self.elapsedSeconds = Int(elapsed)
                self.secondsLeft = max(0, self.maxSeconds - Int(ceil(elapsed)))
                if elapsed >= Double(self.maxSeconds) {
                    self.hitMaxCap = true
                    self.log("maxSeconds reached")
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

        let rawFinal = (lastPassText.isEmpty ? partialText : lastPassText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        log("end take final=\"\(rawFinal)\" auto=\(didAutoFinish) max=\(hitMaxCap) latched=\(passLatched)")
        let expected = expectedPhrase
        tearDown()
        guard !rawFinal.isEmpty else { return "" }
        return isEnglish
            ? PhraseSimilarity.correctSiteASR(rawFinal, expected: expected)
            : rawFinal
    }

    /// User tapped «Готово» / «Стоп» — end recording.
    func finish() {
        guard isCapturing else { return }
        if let start = startedAt, Date().timeIntervalSince(start) < 0.45 {
            // Too early — ignore tap; UI can show hint
            return
        }
        log("user finish")
        resumeWait()
    }

    func cancel() {
        restartTask?.cancel()
        restartTask = nil
        timerTask?.cancel()
        timerTask = nil
        resumeWait()
        tearDown()
    }

    /// Legacy fixed-duration API (maps to maxSeconds auto-stop only). Prefer `captureUntilStopped` + `finish()`.
    func capture(seconds: Int, localeId: String) async -> String {
        await captureUntilStopped(localeId: localeId, maxSeconds: seconds)
    }

    // MARK: - Recognition continuum

    private func startRecognitionTask(reason: String) {
        guard isCapturing, let recognizer else { return }

        // Swap request first so the audio tap never appends into a dead request
        // (trailing words spoken during restart must land on the new task).
        let oldRequest = recognitionRequest
        let oldTask = recognitionTask
        recognitionTask = nil
        segmentPartial = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Dictation for full phrases (search is too keyword-biased for site sentences).
        request.taskHint = .dictation
        request.shouldReportPartialResults = true
        if !isEnglish, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        // Prefer short 1–2 word hints first (Apple guidance); already ordered by caller.
        if !contextualHints.isEmpty {
            request.contextualStrings = contextualHints
        }
        // Publish new request to the tap *before* ending the old one.
        recognitionRequest = request
        oldTask?.cancel()
        oldRequest?.endAudio()

        let gen = restartGeneration
        log("startRecognition reason=\(reason) committed=\"\(committedText)\"")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCapturing, gen == self.restartGeneration else { return }

                if let result {
                    let raw = result.bestTranscription.formattedString
                    let heard = self.isEnglish
                        ? PhraseSimilarity.correctSiteASR(raw, expected: self.expectedPhrase)
                        : raw
                    self.segmentPartial = heard
                    self.publishCombined()
                    self.considerAutoFinish(heard: self.partialText)

                    if result.isFinal {
                        let combined = self.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.log("isFinal segment=\"\(heard)\" combined=\"\(combined)\" latched=\(self.passLatched)")
                        // Full PASS (or latched PASS) → end take immediately.
                        // Translation-app pattern: finalize on complete hypothesis; don't
                        // restart the session and drop trailing words.
                        if self.passLatched || self.shouldAutoFinish(combined) {
                            if self.shouldAutoFinish(combined) {
                                self.lastPassText = combined
                            }
                            self.log("autoFinish on isFinal+fullPass")
                            self.didAutoFinish = true
                            self.passLatched = true
                            self.resumeWait()
                        } else {
                            // Mid-phrase silence / clause break — commit and keep listening.
                            self.commitSegmentAndContinue(reason: "isFinal")
                        }
                    }
                }

                if let error {
                    let ns = error as NSError
                    self.log("recognition error domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription)")
                    // Latched PASS: end rather than restart (avoids trailing-word loss).
                    if self.isCapturing, !self.didAutoFinish, self.passLatched {
                        self.didAutoFinish = true
                        self.resumeWait()
                    } else if self.isCapturing, !self.didAutoFinish {
                        // Don't end the take — Speech often errors after isFinal; restart.
                        self.commitSegmentAndContinue(reason: "error")
                    }
                }
            }
        }
    }

    private func publishCombined() {
        let combined = Self.joinTranscript(committed: committedText, segment: segmentPartial)
        partialText = isEnglish
            ? PhraseSimilarity.correctSiteASR(combined, expected: expectedPhrase)
            : combined
    }

    private func commitSegmentAndContinue(reason: String) {
        guard isCapturing, !didAutoFinish else { return }
        // If we already saw a full PASS, finalize instead of restarting (trailing words).
        if passLatched {
            log("skip restart; pass latched reason=\(reason)")
            didAutoFinish = true
            resumeWait()
            return
        }
        let piece = segmentPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !piece.isEmpty {
            committedText = Self.joinTranscript(committed: committedText, segment: piece)
            segmentPartial = ""
            publishCombined()
            log("commit reason=\(reason) committed=\"\(committedText)\"")
            considerAutoFinish(heard: partialText)
            if didAutoFinish { return }
        }
        scheduleRecognitionRestart(reason: reason)
    }

    private func scheduleRecognitionRestart(reason: String) {
        guard isCapturing, !didAutoFinish else { return }
        restartTask?.cancel()
        let gen = restartGeneration
        restartTask = Task { @MainActor in
            // Brief gap so the previous task can release; keep short so trailing words aren't lost.
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled, gen == self.restartGeneration else { return }
            guard self.isCapturing, !self.didAutoFinish else { return }
            // Re-assert recording session after TTS / route blips.
            do {
                try AudioSessionManager.configureForRecording()
            } catch {
                self.log("reconfigure failed: \(error.localizedDescription)")
            }
            if !self.audioEngine.isRunning {
                do {
                    try self.audioEngine.start()
                    self.log("engine restarted")
                } catch {
                    self.errorMessage = "Микрофон"
                    self.log("engine restart failed: \(error.localizedDescription)")
                    self.resumeWait()
                    return
                }
            }
            self.startRecognitionTask(reason: "restart:\(reason)")
        }
    }

    private func resumeWait() {
        if let cont = waitContinuation {
            waitContinuation = nil
            cont.resume()
        }
    }

    /// Auto-finish only when full-phrase PASS (incl. trailing tokens) stays true briefly.
    /// Latch on first full PASS so SFSpeech partial regressions cannot clear the hold
    /// (common hang: UI shows complete phrase, capture never ends).
    private func considerAutoFinish(heard: String) {
        guard !didAutoFinish, isCapturing else { return }
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        guard elapsed >= 0.25 else { return }

        let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let passing = shouldAutoFinish(trimmed)

        if passing {
            lastPassText = trimmed
            passLatched = true
            let key = PhraseSimilarity.stablePassKey(trimmed)
            if autoFinishHoldText != key {
                // Keep earliest hold start so jitter between equivalent PASS keys still finishes.
                if autoFinishHoldSince == nil {
                    autoFinishHoldSince = Date()
                    log("pass hold start \"\(trimmed)\" key=\"\(key)\"")
                }
                autoFinishHoldText = key
            }
        } else if !passLatched {
            autoFinishHoldSince = nil
            autoFinishHoldText = ""
            return
        }
        // Latched but current partial regressed — keep hold clock; finish on lastPassText.

        let held = autoFinishHoldSince.map { Date().timeIntervalSince($0) } ?? 0
        guard held >= autoFinishHoldSeconds else { return }

        log("autoFinish after \(String(format: "%.2f", held))s \"\(lastPassText)\" latched=\(passLatched)")
        didAutoFinish = true
        autoFinishHoldSince = nil
        autoFinishHoldText = ""
        resumeWait()
    }

    /// Predicate PASS plus progressive coverage of every expected token (blocks prefix finish).
    private func shouldAutoFinish(_ heard: String) -> Bool {
        let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let pred = autoFinishWhen, pred(trimmed) else { return false }
        guard !expectedPhrase.isEmpty else { return true }
        // Belt-and-suspenders: never finish on «where is my» while target still has «hard hat».
        let complete = PhraseSimilarity.isCompleteProgressiveMatch(
            recognized: trimmed,
            expected: expectedPhrase,
            useTalkNormalize: true
        )
        if !complete {
            log("block early finish; progressive incomplete for \"\(expectedPhrase)\" got=\"\(trimmed)\"")
        }
        return complete
    }

    private func tearDown() {
        isCapturing = false
        autoFinishWhen = nil
        expectedPhrase = ""
        autoFinishHoldSince = nil
        autoFinishHoldText = ""
        passLatched = false
        // Keep lastPassText until captureUntilStopped reads it; cleared on next start.
        restartTask?.cancel()
        restartTask = nil
        timerTask?.cancel()
        timerTask = nil
        removeInterruptionObserver()
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil
        startedAt = nil
        secondsLeft = 0
        restartGeneration &+= 1
    }

    private func installInterruptionObserver() {
        removeInterruptionObserver()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handleInterruption(note)
            }
        }
    }

    private func removeInterruptionObserver() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard isCapturing else { return }
        guard let info = note.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
        switch type {
        case .began:
            log("session interruption began")
        case .ended:
            log("session interruption ended — restart recognition")
            scheduleRecognitionRestart(reason: "interruptionEnded")
        @unknown default:
            break
        }
    }

    private static func joinTranscript(committed: String, segment: String) -> String {
        let a = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }

        let aKey = a.lowercased()
        let bKey = b.lowercased()
        // Exact / full-prefix repeats from a new SFSpeech utterance.
        if bKey == aKey { return b }
        if bKey.hasPrefix(aKey + " ") || bKey.hasPrefix(aKey) && bKey.count > aKey.count {
            return b
        }
        if aKey.hasSuffix(" " + bKey) || aKey.hasSuffix(bKey) && aKey.count > bKey.count {
            return a
        }

        // Token overlap only (never substring contains — that dropped trailing words).
        let aToks = aKey.split(separator: " ").map(String.init)
        let bToks = bKey.split(separator: " ").map(String.init)
        if !aToks.isEmpty, !bToks.isEmpty {
            let maxOverlap = min(aToks.count, bToks.count)
            var overlap = 0
            for n in stride(from: maxOverlap, through: 1, by: -1) {
                if Array(aToks.suffix(n)) == Array(bToks.prefix(n)) {
                    overlap = n
                    break
                }
            }
            if overlap > 0 {
                let bOrig = b.split { $0.isWhitespace || $0.isNewline }.map(String.init).filter { !$0.isEmpty }
                let restOrig = Array(bOrig.dropFirst(overlap))
                if restOrig.isEmpty { return a }
                return ([a] + restOrig).joined(separator: " ")
            }
        }

        return a + " " + b
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

    private func log(_ message: String) {
        print("[EOSSpeak] \(message)")
    }
}

/// Holds the active buffer request for the audio tap (non-main queue).
private final class RequestBox: @unchecked Sendable {
    var request: SFSpeechAudioBufferRecognitionRequest?
}
