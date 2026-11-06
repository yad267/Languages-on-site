import AVFoundation
import Foundation
import Observation

/// Watch-side mic capture only. Speech.framework is NOT available on watchOS —
/// transcription goes to iPhone via `recognizeRemote` (WatchConnectivity).
@Observable
@MainActor
final class WatchSpeechCapture: NSObject {
    private(set) var isCapturing = false
    private(set) var secondsLeft = 0
    private(set) var partialText = ""

    /// Injected by WatchAppModel: send recorded audio to phone, get transcript.
    var recognizeRemote: ((Data, String) async -> String)?

    private var recorder: AVAudioRecorder?
    private var timerTask: Task<Void, Never>?
    private var recordURL: URL?

    func capture(seconds: Int, localeId: String = "ru-RU") async -> String {
        cancel()
        partialText = ""
        secondsLeft = seconds

        let micOK = await AVAudioApplication.requestRecordPermission()
        guard micOK else { return "" }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: [])
        try? session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-cap-\(UUID().uuidString).m4a")
        recordURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.delegate = self
            guard rec.prepareToRecord(), rec.record() else { return "" }
            recorder = rec
        } catch {
            return ""
        }

        isCapturing = true
        timerTask = Task { @MainActor in
            while self.secondsLeft > 0 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                self.secondsLeft -= 1
            }
        }
        await timerTask?.value

        recorder?.stop()
        recorder = nil
        isCapturing = false
        secondsLeft = 0

        guard let url = recordURL,
              let data = try? Data(contentsOf: url),
              data.count > 200 else {
            cleanupFile()
            return ""
        }
        cleanupFile()

        partialText = "…"
        if let recognizeRemote {
            let text = await recognizeRemote(data, localeId)
            partialText = text
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    func cancel() {
        timerTask?.cancel()
        timerTask = nil
        recorder?.stop()
        recorder = nil
        isCapturing = false
        secondsLeft = 0
        cleanupFile()
    }

    private func cleanupFile() {
        if let url = recordURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordURL = nil
    }
}

extension WatchSpeechCapture: AVAudioRecorderDelegate {}
