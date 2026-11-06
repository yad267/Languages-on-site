import Foundation

/// Optional POST to owner n8n webhook → Drive (EOS channel assets). Empty URL = quiet skip.
enum EosSyncService {
    struct AudioPayload {
        var lessonId: String
        var lineId: String
        var role: String
        var textEN: String
        var textRU: String
        var voiceId: String
        var audioBase64: String
        var contentVersion: Int
    }

    /// After a *new* EL mp3 is written to disk cache.
    static func postAudioIfConfigured(settings: AppSettings, payload: AudioPayload) {
        let urlString = settings.eosSyncWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return }

        let body: [String: Any] = [
            "type": "tts_audio",
            "lessonId": payload.lessonId,
            "lineId": payload.lineId,
            "role": payload.role,
            "text_en": payload.textEN,
            "text_ru": payload.textRU,
            "voiceId": payload.voiceId,
            "audio": payload.audioBase64,
            "content_version": payload.contentVersion,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        postJSON(url: url, body: body, label: "tts_audio")
    }

    /// After lesson pack download/apply.
    static func postLessonPackIfConfigured(
        settings: AppSettings,
        contentVersion: Int,
        packJSON: Data
    ) {
        let urlString = settings.eosSyncWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return }

        let packObject = (try? JSONSerialization.jsonObject(with: packJSON)) ?? NSNull()
        let body: [String: Any] = [
            "type": "lesson_pack",
            "content_version": contentVersion,
            "lesson_pack": packObject,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        postJSON(url: url, body: body, label: "lesson_pack")
    }

    private static func postJSON(url: URL, body: [String: Any], label: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        Task.detached(priority: .utility) {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                print("[eos-sync] \(label) HTTP \(code)")
            } catch {
                print("[eos-sync] \(label) skip/fail \(error.localizedDescription.prefix(60))")
            }
        }
    }
}

/// Optional context so TTS can POST newly cached audio to webhook.
struct EosTTSSyncContext: Sendable {
    var lessonId: String
    var lineId: String
    var role: String
    var textEN: String
    var textRU: String
    var contentVersion: Int
}
