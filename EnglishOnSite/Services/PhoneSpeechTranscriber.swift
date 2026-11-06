import Foundation
import Speech

/// Runs on iPhone — Watch has no Speech.framework in watchOS SDK.
enum PhoneSpeechTranscriber {
    static func transcribe(audio: Data, localeId: String, format: String = "m4a") async -> String {
        let speechOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                c.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return "" }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)),
              recognizer.isAvailable else { return "" }

        let ext = format.isEmpty ? "m4a" : format
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-stt-\(UUID().uuidString).\(ext)")
        do {
            try audio.write(to: url)
        } catch {
            return ""
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let request = SFSpeechURLRecognitionRequest(url: url)
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let lock = NSLock()
            var settled = false
            func finish(_ text: String) {
                lock.lock()
                defer { lock.unlock() }
                guard !settled else { return }
                settled = true
                cont.resume(returning: text)
            }

            recognizer.recognitionTask(with: request) { result, error in
                if error != nil {
                    finish("")
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    finish(text)
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                finish("")
            }
        }
    }
}
