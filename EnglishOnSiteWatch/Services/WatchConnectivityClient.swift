import Foundation
import WatchConnectivity
import Observation

@Observable
@MainActor
final class WatchConnectivityClient: NSObject {
    private(set) var isReachable = false
    private(set) var lastSettings: WCSettingsPayload?
    private var pending: [String: CheckedContinuation<WCPhraseResult?, Never>] = [:]
    private var pendingTranscript: [String: CheckedContinuation<String, Never>] = [:]

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    var phoneReachable: Bool {
        WCSession.isSupported() && WCSession.default.isReachable
    }

    /// Send Watch-recorded audio to iPhone for SFSpeech.
    func requestTranscribe(audio: Data, locale: String) async -> String {
        guard phoneReachable else { return "" }
        // WCSession sendMessage practical limit — skip if too large
        let b64 = audio.base64EncodedString()
        guard b64.count < 55_000 else { return "" }

        let id = UUID().uuidString
        let env = WCEnvelope(
            type: WCMsgType.recognizeAudio.rawValue,
            requestId: id,
            payload: [
                "audioBase64": b64,
                "locale": locale,
                "format": "m4a",
            ]
        )
        guard let data = try? JSONEncoder().encode(env),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }

        return await withCheckedContinuation { cont in
            pendingTranscript[id] = cont
            WCSession.default.sendMessage(dict, replyHandler: { [weak self] reply in
                Task { @MainActor in
                    let text = (reply["transcript"] as? String) ?? ""
                    self?.pendingTranscript.removeValue(forKey: id)?.resume(returning: text)
                }
            }, errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.pendingTranscript.removeValue(forKey: id)?.resume(returning: "")
                }
            })
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 16_000_000_000)
                if self.pendingTranscript[id] != nil {
                    self.pendingTranscript.removeValue(forKey: id)?.resume(returning: "")
                }
            }
        }
    }

    func requestTranslate(text: String) async -> WCPhraseResult? {
        await sendExpectingResult(type: .translate, payload: ["text": text])
    }

    func requestRemember(transcript: String, seconds: Int) async -> WCPhraseResult? {
        await sendExpectingResult(
            type: .remember,
            payload: ["transcript": transcript, "seconds": String(seconds)]
        )
    }

    func requestReviewNext() async -> WCPhraseResult? {
        await sendExpectingResult(type: .reviewNext, payload: [:])
    }

    func sendLessonCommand(_ cmd: WCLessonCommand) {
        guard phoneReachable else { return }
        let env = WCEnvelope(
            type: WCMsgType.lessonCommand.rawValue,
            requestId: UUID().uuidString,
            payload: ["command": cmd.rawValue]
        )
        guard let data = try? JSONEncoder().encode(env),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        WCSession.default.sendMessage(dict, replyHandler: nil, errorHandler: nil)
    }

    private func sendExpectingResult(type: WCMsgType, payload: [String: String]) async -> WCPhraseResult? {
        guard phoneReachable else { return nil }
        let id = UUID().uuidString
        let env = WCEnvelope(type: type.rawValue, requestId: id, payload: payload)
        guard let data = try? JSONEncoder().encode(env),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        return await withCheckedContinuation { cont in
            pending[id] = cont
            WCSession.default.sendMessage(dict, replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.resolve(requestId: id, reply: reply)
                }
            }, errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.fail(requestId: id)
                }
            })
            // Safety timeout
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 14_000_000_000)
                if self.pending[id] != nil {
                    self.fail(requestId: id)
                }
            }
        }
    }

    private func resolve(requestId: String, reply: [String: Any]) {
        guard let cont = pending.removeValue(forKey: requestId) else { return }
        if let data = try? JSONSerialization.data(withJSONObject: reply),
           let result = try? JSONDecoder().decode(WCPhraseResult.self, from: data) {
            cont.resume(returning: result)
        } else if let envData = try? JSONSerialization.data(withJSONObject: reply),
                  let env = try? JSONDecoder().decode(WCEnvelope.self, from: envData),
                  env.type == WCMsgType.result.rawValue {
            let result = WCPhraseResult(
                requestId: env.requestId,
                en: env.payload["en"] ?? "",
                ru: env.payload["ru"] ?? "",
                tipRu: env.payload["tipRu"] ?? "",
                source: env.payload["source"] ?? "offline",
                colloquialNoteRu: env.payload["colloquialNoteRu"],
                transcript: env.payload["transcript"],
                tag: env.payload["tag"]
            )
            cont.resume(returning: result)
        } else {
            cont.resume(returning: nil)
        }
    }

    private func fail(requestId: String) {
        pending.removeValue(forKey: requestId)?.resume(returning: nil)
    }

    private func handleSettings(_ applicationContext: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: applicationContext),
              let settings = try? JSONDecoder().decode(WCSettingsPayload.self, from: data) else { return }
        lastSettings = settings
    }
}

extension WatchConnectivityClient: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if !session.receivedApplicationContext.isEmpty {
                self.handleSettings(session.receivedApplicationContext)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.handleSettings(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // Phone may push unsolicited results — ignore for v2.0
        _ = message
    }
}
