import Foundation
import WatchConnectivity
import SwiftData
import Observation

@MainActor
@Observable
final class PhoneWatchBridge: NSObject {
    static let shared = PhoneWatchBridge()

    private var settings: AppSettings?
    private var modelContainer: ModelContainer?

    func configure(settings: AppSettings, container: ModelContainer) {
        self.settings = settings
        self.modelContainer = container
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        pushSettings()
    }

    func pushSettings() {
        guard WCSession.isSupported(), let settings else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        let payload = WCSettingsPayload(
            geminiEnabled: settings.geminiEnabledAndReady,
            rememberSeconds: settings.rememberDuration.rawValue,
            translateSeconds: settings.translateDuration.rawValue,
            enSpeechRate: settings.englishRate,
            rememberLocale: settings.rememberLocale.rawValue,
            stopWords: settings.voiceCommands.stop.joined(separator: ","),
            pauseWords: settings.voiceCommands.pause.joined(separator: ","),
            resumeWords: settings.voiceCommands.resume.joined(separator: ","),
            repeatWords: settings.voiceCommands.repeatLast.joined(separator: ","),
            translateWords: settings.voiceCommands.translate.joined(separator: ","),
            rememberWords: settings.voiceCommands.remember.joined(separator: ",")
        )
        guard let data = try? JSONEncoder().encode(payload),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try? session.updateApplicationContext(dict)
    }

    private func handleMessage(_ message: [String: Any], reply: (([String: Any]) -> Void)?) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: message),
            let env = try? JSONDecoder().decode(WCEnvelope.self, from: data),
            let type = WCMsgType(rawValue: env.type)
        else {
            reply?(["type": WCMsgType.error.rawValue, "requestId": "", "en": "", "ru": "bad message", "tipRu": "", "source": "offline"])
            return
        }

        Task { @MainActor in
            switch type {
            case .lessonCommand:
                if let raw = env.payload["command"], let cmd = WCLessonCommand(rawValue: raw) {
                    PhoneLessonRelay.shared.handle(cmd)
                }
                reply?(["ok": "1"])

            case .translate:
                let text = env.payload["text"] ?? ""
                let result = await processTranslate(text: text, requestId: env.requestId)
                reply?(encodeResult(result))

            case .remember:
                let transcript = env.payload["transcript"] ?? ""
                let result = await processRemember(transcript: transcript, requestId: env.requestId)
                reply?(encodeResult(result))

            case .reviewNext:
                let result = processReviewNext(requestId: env.requestId)
                reply?(encodeResult(result))

            case .recognizeAudio:
                let b64 = env.payload["audioBase64"] ?? ""
                let locale = env.payload["locale"] ?? "ru-RU"
                let format = env.payload["format"] ?? "m4a"
                guard let audio = Data(base64Encoded: b64), !audio.isEmpty else {
                    reply?(["requestId": env.requestId, "transcript": ""])
                    return
                }
                let text = await PhoneSpeechTranscriber.transcribe(
                    audio: audio,
                    localeId: locale,
                    format: format
                )
                reply?(["requestId": env.requestId, "transcript": text])

            default:
                reply?(["ok": "1"])
            }
        }
    }

    private func processTranslate(text: String, requestId: String) async -> WCPhraseResult {
        guard let settings else {
            return offlineFail(requestId: requestId, text: text)
        }
        let result = await TranslationService.translate(recognized: text, settings: settings)
        let en = result.sourceIsRussian ? result.translatedText : result.sourceText
        let ru = result.sourceIsRussian ? result.sourceText : result.translatedText
        if result.matched || result.viaGemini {
            _ = try? saveLibrary(
                source: .translate,
                en: en.contains("позже") ? result.sourceText : en,
                ru: ru,
                tip: result.tipRu,
                tag: result.tag,
                transcript: result.sourceText
            )
        }
        return WCPhraseResult(
            requestId: requestId,
            en: en,
            ru: ru,
            tipRu: result.tipRu,
            source: result.viaGemini ? "gemini" : "offline",
            colloquialNoteRu: nil,
            transcript: result.sourceText,
            tag: result.tag.rawValue
        )
    }

    private func processRemember(transcript: String, requestId: String) async -> WCPhraseResult {
        guard let settings else {
            return offlineFail(requestId: requestId, text: transcript)
        }
        let (offline, gemini) = await RememberCaptureService.analyze(
            transcript: transcript,
            settings: settings,
            lessonTags: []
        )
        let best = gemini ?? offline
        _ = try? saveLibrary(
            source: .remember,
            en: best.sayIt,
            ru: best.ruMeaning,
            tip: best.tipRu,
            tag: best.tag,
            transcript: best.transcriptRaw
        )
        return WCPhraseResult(
            requestId: requestId,
            en: best.sayIt,
            ru: best.ruMeaning,
            tipRu: best.tipRu,
            source: best.viaGemini ? "gemini" : "offline",
            colloquialNoteRu: best.colloquialNoteRu,
            transcript: best.transcriptRaw,
            tag: best.tag.rawValue
        )
    }

    private func processReviewNext(requestId: String) -> WCPhraseResult {
        guard let container = modelContainer else {
            return WCPhraseResult(
                requestId: requestId,
                en: "I'm upstairs.",
                ru: "Я наверху.",
                tipRu: "Нет связи с библиотекой",
                source: "offline",
                colloquialNoteRu: nil,
                transcript: nil,
                tag: "electrical"
            )
        }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<LibraryItem>(sortBy: [SortDescriptor(\.nextReviewAt)])
        let items = (try? context.fetch(descriptor)) ?? []
        let due = LibraryStore.dueItems(items, limit: 1)
        if let item = due.first {
            return WCPhraseResult(
                requestId: requestId,
                en: item.en,
                ru: item.ru,
                tipRu: item.tipRu,
                source: "offline",
                colloquialNoteRu: nil,
                transcript: nil,
                tag: item.tag.rawValue
            )
        }
        if let any = items.first {
            return WCPhraseResult(
                requestId: requestId,
                en: any.en,
                ru: any.ru,
                tipRu: any.tipRu,
                source: "offline",
                colloquialNoteRu: nil,
                transcript: nil,
                tag: any.tag.rawValue
            )
        }
        // Fallback demo from bank
        if let hit = PhraseBank.all().first {
            return WCPhraseResult(
                requestId: requestId,
                en: hit.en,
                ru: hit.ru,
                tipRu: hit.tipRu,
                source: "offline",
                colloquialNoteRu: nil,
                transcript: nil,
                tag: hit.tag
            )
        }
        return offlineFail(requestId: requestId, text: "")
    }

    private func saveLibrary(
        source: LibrarySource,
        en: String,
        ru: String,
        tip: String,
        tag: LibraryTag,
        transcript: String
    ) throws -> LibraryItem {
        guard let container = modelContainer else {
            throw NSError(domain: "PhoneWatchBridge", code: 1)
        }
        let context = ModelContext(container)
        return LibraryStore.add(
            context: context,
            source: source,
            en: en,
            ru: ru,
            tipRu: tip,
            tag: tag,
            transcriptRaw: transcript
        )
    }

    private func offlineFail(requestId: String, text: String) -> WCPhraseResult {
        WCPhraseResult(
            requestId: requestId,
            en: text.isEmpty ? "—" : text,
            ru: "(нет ответа)",
            tipRu: "",
            source: "offline",
            colloquialNoteRu: nil,
            transcript: text,
            tag: "other"
        )
    }

    private func encodeResult(_ result: WCPhraseResult) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(result))) as? [String: Any]
            ?? [
                "requestId": result.requestId,
                "en": result.en,
                "ru": result.ru,
                "tipRu": result.tipRu,
                "source": result.source,
            ]
    }
}

extension PhoneWatchBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.pushSettings()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            self.handleMessage(message, reply: replyHandler)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.handleMessage(message, reply: nil)
        }
    }
}
