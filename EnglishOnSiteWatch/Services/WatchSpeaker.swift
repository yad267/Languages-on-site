import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class WatchSpeaker: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [(String, Bool)] = []
    var enRate: Float = 0.42
    private(set) var isSpeaking = false
    private var onDone: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func stop() {
        queue.removeAll()
        onDone = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speakENThenRU(en: String, ru: String, tip: String? = nil, then done: (() -> Void)? = nil) {
        stop()
        configureSession()
        onDone = done
        queue = [(en, true), (ru, false)]
        if let tip, !tip.isEmpty {
            queue.append((tip, false))
        }
        isSpeaking = true
        speakNext()
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    private func speakNext() {
        guard !queue.isEmpty else {
            isSpeaking = false
            let d = onDone
            onDone = nil
            d?()
            return
        }
        let (text, isEN) = queue.removeFirst()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            speakNext()
            return
        }
        let u = AVSpeechUtterance(string: text)
        if isEN {
            u.voice = AVSpeechSynthesisVoice(language: "en-IE")
                ?? AVSpeechSynthesisVoice(language: "en-GB")
                ?? AVSpeechSynthesisVoice(language: "en-US")
            u.rate = enRate
        } else {
            u.voice = AVSpeechSynthesisVoice(language: "ru-RU")
            u.rate = 0.50
        }
        u.preUtteranceDelay = 0.08
        u.postUtteranceDelay = 0.15
        synthesizer.speak(u)
    }
}

extension WatchSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakNext() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.queue.removeAll()
            self.isSpeaking = false
        }
    }
}
