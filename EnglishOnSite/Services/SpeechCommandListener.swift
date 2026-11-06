import AVFoundation
import Foundation
import Observation
import Speech

@Observable
@MainActor
final class SpeechCommandListener {
    private(set) var isListening = false
    private(set) var lastHeard = ""
    private(set) var authorizationMessage = ""

    private var settings: AppSettings
    private var onCommand: ((VoiceCommandAction) -> Void)?
    private var shouldListen = false

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))

    private var lastActionAt: Date = .distantPast
    private let cooldown: TimeInterval = 1.2

    init(settings: AppSettings) {
        self.settings = settings
    }

    func updateSettings(_ settings: AppSettings) {
        self.settings = settings
    }

    func setCommandHandler(_ handler: @escaping (VoiceCommandAction) -> Void) {
        onCommand = handler
    }

    func requestAuthorizationIfNeeded() async {
        let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }

        switch speechStatus {
        case .authorized:
            authorizationMessage = ""
        case .denied:
            authorizationMessage = "Нет доступа к распознаванию речи"
        case .restricted:
            authorizationMessage = "Распознавание речи ограничено"
        case .notDetermined:
            authorizationMessage = "Разрешение не запрошено"
        @unknown default:
            authorizationMessage = "Неизвестный статус Speech"
        }

        let micGranted = await AVAudioApplication.requestRecordPermission()
        if !micGranted {
            authorizationMessage = "Нужен микрофон для команд"
        }
    }

    func start() {
        shouldListen = true
        beginListeningSession()
    }

    func stop() {
        shouldListen = false
        tearDownEngine()
    }

    private func beginListeningSession() {
        guard shouldListen else { return }
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            authorizationMessage = "Распознавание ru-RU недоступно"
            return
        }

        tearDownEngine()

        do {
            try AudioSessionManager.configureForLesson()
        } catch {
            authorizationMessage = "Аудиосессия: \(error.localizedDescription)"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.lastHeard = text
                    self.process(text: text)
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.scheduleRestartIfNeeded()
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
        } catch {
            authorizationMessage = "Микрофон: \(error.localizedDescription)"
            tearDownEngine()
        }
    }

    private func tearDownEngine() {
        isListening = false
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func scheduleRestartIfNeeded() {
        guard shouldListen else { return }
        tearDownEngine()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if self.shouldListen {
                self.beginListeningSession()
            }
        }
    }

    private func process(text: String) {
        guard let action = settings.voiceCommands.match(in: text) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastActionAt) >= cooldown else { return }
        lastActionAt = now
        onCommand?(action)
    }
}
