import Foundation
import Observation
import WatchKit

@Observable
@MainActor
final class WatchAppModel {
    enum Status: String {
        case idle = "Готов"
        case listening = "Слушаю…"
        case thinking = "Думаю…"
        case speaking = "Говорю…"
        case done = "Готово"
        case noHear = "Не слышу, повтори"
    }

    var status: Status = .idle
    var enText = ""
    var ruText = ""
    var tipText = ""
    var transcript = ""
    var sourceLabel = "Офлайн"
    var secondsLeft = 0
    var phoneConnected = false

    let session = WatchConnectivityClient()
    let capture = WatchSpeechCapture()
    let speaker = WatchSpeaker()

    private var translateSeconds: Int { session.lastSettings?.translateSeconds ?? 6 }
    private var rememberSeconds: Int { session.lastSettings?.rememberSeconds ?? 45 }

    func activate() {
        capture.recognizeRemote = { [weak self] data, locale in
            await self?.session.requestTranscribe(audio: data, locale: locale) ?? ""
        }
        session.activate()
        refreshConnection()
        if let rate = session.lastSettings?.enSpeechRate {
            speaker.enRate = rate
        }
    }

    func refreshConnection() {
        phoneConnected = session.phoneReachable
        if let rate = session.lastSettings?.enSpeechRate {
            speaker.enRate = rate
        }
    }

    func stopSpeech() {
        speaker.stop()
        status = .idle
    }

    /// Main big button
    func tapListen() {
        Task { await runListenFlow() }
    }

    func tapTranslate() {
        Task { await runListenFlow(forceTranslate: true) }
    }

    func tapRemember() {
        Task { await runRemember() }
    }

    func tapReview() {
        Task { await runReview() }
    }

    func tapStopLesson() {
        refreshConnection()
        if phoneConnected {
            session.sendLessonCommand(.stop)
            status = .done
            WKInterfaceDevice.current().play(.click)
        }
    }

    private func runListenFlow(forceTranslate: Bool = false) async {
        refreshConnection()
        speaker.stop()
        status = .listening
        enText = ""
        ruText = ""
        tipText = ""
        transcript = ""
        WKInterfaceDevice.current().play(.start)

        let text = await capture.capture(seconds: translateSeconds, localeId: "ru-RU")
        secondsLeft = 0
        let recognized: String
        if text.isEmpty {
            // Simulator / noisy site fallback demo
            recognized = forceTranslate ? "Where's the consumer unit?" : "перевод Where's the consumer unit?"
            transcript = "(демо) \(recognized)"
        } else {
            recognized = text
            transcript = text
        }

        let lowered = recognized.lowercased()
        let settings = session.lastSettings

        if matches(lowered, words: settings?.rememberWords ?? "запомни,запомнить") {
            await runRemember(seedTranscript: nil)
            return
        }
        if matches(lowered, words: settings?.repeatWords ?? "повтори,повтор,ещё раз,еще раз") {
            await runReview()
            return
        }
        if matches(lowered, words: settings?.stopWords ?? "стоп,стой")
            || matches(lowered, words: settings?.pauseWords ?? "пауза") {
            session.sendLessonCommand(.stop)
            status = .done
            WKInterfaceDevice.current().play(.click)
            return
        }
        if matches(lowered, words: settings?.resumeWords ?? "дальше,продолжай,продолжить") {
            session.sendLessonCommand(.resume)
            status = .done
            return
        }

        var phrase = recognized
        if matches(lowered, words: settings?.translateWords ?? "перевод,переведи") || forceTranslate {
            phrase = stripCommand(recognized, words: settings?.translateWords ?? "перевод,переведи")
            if phrase.count < 3 {
                // wait was same session — use demo if empty
                phrase = text.isEmpty ? "Where's the consumer unit?" : phrase
            }
        }

        if phrase.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
            status = .noHear
            WKInterfaceDevice.current().play(.failure)
            return
        }

        await deliverTranslate(phrase)
    }

    private func runRemember(seedTranscript: String? = nil) async {
        refreshConnection()
        speaker.stop()
        status = .listening
        WKInterfaceDevice.current().play(.start)

        let raw: String
        if let seedTranscript, !seedTranscript.isEmpty {
            raw = seedTranscript
        } else {
            let text = await capture.capture(
                seconds: rememberSeconds,
                localeId: session.lastSettings?.rememberLocale ?? "en-IE"
            )
            if text.isEmpty {
                raw = "Flip the main isolator off."
                transcript = "(демо) \(raw)"
            } else {
                raw = text
                transcript = text
            }
        }

        status = .thinking
        if phoneConnected, let result = await session.requestRemember(transcript: raw, seconds: rememberSeconds) {
            apply(result)
            speakCurrent()
            return
        }

        // Offline watch fallback
        if let hit = WatchOfflineBank.lookup(raw) {
            applyLocal(en: hit.en, ru: hit.ru, tip: hit.tipRu, source: "offline")
        } else {
            applyLocal(
                en: raw,
                ru: "(разбор на iPhone)",
                tip: "Подключи iPhone для Gemini / полной библиотеки.",
                source: "offline"
            )
        }
        speakCurrent()
    }

    private func runReview() async {
        refreshConnection()
        status = .thinking
        if phoneConnected, let result = await session.requestReviewNext() {
            apply(result)
            speakCurrent()
            return
        }
        // Offline: random bank phrase as "review"
        if let hit = WatchOfflineBank.all().randomElement() {
            applyLocal(en: hit.en, ru: hit.ru, tip: hit.tipRu, source: "offline")
            speakCurrent()
        } else {
            status = .noHear
        }
    }

    private func deliverTranslate(_ phrase: String) async {
        status = .thinking
        if phoneConnected, let result = await session.requestTranslate(text: phrase) {
            apply(result)
            speakCurrent()
            return
        }
        if let hit = WatchOfflineBank.lookup(phrase) {
            let isRU = WatchOfflineBank.containsCyrillic(phrase)
            if isRU {
                applyLocal(en: hit.en, ru: hit.ru, tip: hit.tipRu, source: "offline")
            } else {
                applyLocal(en: hit.en, ru: hit.ru, tip: hit.tipRu, source: "offline")
            }
        } else {
            applyLocal(
                en: phrase,
                ru: "(нет офлайн-пары)",
                tip: "Нужен iPhone для Gemini.",
                source: "offline"
            )
        }
        speakCurrent()
    }

    private func apply(_ result: WCPhraseResult) {
        enText = result.en
        ruText = result.ru
        tipText = result.tipRu
        sourceLabel = result.source == "gemini" ? "Gemini" : "Офлайн"
        if let t = result.transcript, !t.isEmpty { transcript = t }
        status = .done
    }

    private func applyLocal(en: String, ru: String, tip: String, source: String) {
        enText = en
        ruText = ru
        tipText = tip
        sourceLabel = source == "gemini" ? "Gemini" : "Офлайн"
        status = .done
    }

    private func speakCurrent() {
        WKInterfaceDevice.current().play(.success)
        status = .speaking
        speaker.speakENThenRU(en: enText, ru: ruText, tip: tipText.isEmpty ? nil : tipText) { [weak self] in
            self?.status = .done
        }
    }

    private func matches(_ text: String, words: String) -> Bool {
        let list = words.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return list.contains { !$0.isEmpty && text.contains($0) }
    }

    private func stripCommand(_ text: String, words: String) -> String {
        var t = text
        for w in words.split(separator: ",") {
            let raw = String(w).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            if let r = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: raw))\\b", options: .caseInsensitive) {
                t = r.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
