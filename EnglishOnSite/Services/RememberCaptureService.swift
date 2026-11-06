import Foundation

struct RememberBreakdown {
    var extractedPhrase: String
    var ruMeaning: String
    var tipRu: String
    var sayIt: String
    var tag: LibraryTag
    var transcriptRaw: String
    var matched: Bool
    var colloquialNoteRu: String?
    var viaGemini: Bool

    static func from(analysis: RememberAnalysis, transcript: String) -> RememberBreakdown {
        RememberBreakdown(
            extractedPhrase: analysis.en,
            ruMeaning: analysis.ru,
            tipRu: analysis.tipRu,
            sayIt: analysis.sayIt,
            tag: analysis.tag,
            transcriptRaw: transcript,
            matched: true,
            colloquialNoteRu: analysis.colloquialNoteRu,
            viaGemini: true
        )
    }
}

enum RememberCaptureService {
    static func analyzeOffline(transcript: String) -> RememberBreakdown {
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let extracted = extractPhrase(from: raw)
        let sayIt = normalizeSayIt(extracted.isEmpty ? raw : extracted)

        if let hit = PhraseBank.searchBank(normalized: sayIt.isEmpty ? raw : sayIt) {
            return RememberBreakdown(
                extractedPhrase: hit.en,
                ruMeaning: hit.ru,
                tipRu: hit.tipRu.isEmpty ? "Так говорят на объекте в Ireland." : hit.tipRu,
                sayIt: hit.en,
                tag: hit.libraryTag,
                transcriptRaw: raw,
                matched: true,
                colloquialNoteRu: nil,
                viaGemini: false
            )
        }

        let phrase = sayIt.isEmpty ? (raw.isEmpty ? "…" : raw) : sayIt
        return RememberBreakdown(
            extractedPhrase: phrase,
            ruMeaning: "(разбор позже)",
            tipRu: "Услышал на объекте — повтори медленно и уточни перевод позже.",
            sayIt: phrase,
            tag: .other,
            transcriptRaw: raw,
            matched: false,
            colloquialNoteRu: nil,
            viaGemini: false
        )
    }

    /// Offline first; optionally enrich with Gemini.
    static func analyze(
        transcript: String,
        settings: AppSettings,
        lessonTags: [String] = []
    ) async -> (offline: RememberBreakdown, gemini: RememberBreakdown?) {
        let offline = analyzeOffline(transcript: transcript)
        guard settings.geminiEnabledAndReady else {
            return (offline, nil)
        }
        guard transcript.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            return (offline, nil)
        }

        if let analysis = await GeminiSiteCoachService.shared.analyzeRemember(
            transcript: transcript,
            preferredLocale: settings.rememberLocale.rawValue,
            lessonTags: lessonTags
        ) {
            return (offline, RememberBreakdown.from(analysis: analysis, transcript: offline.transcriptRaw))
        }
        return (offline, nil)
    }

    private static func extractPhrase(from text: String) -> String {
        guard !text.isEmpty else { return "" }
        let parts = text
            .replacingOccurrences(of: "?", with: "?.")
            .components(separatedBy: CharacterSet(charactersIn: ".!"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parts.isEmpty { return text }
        let ranked = parts.sorted { a, b in
            let wa = a.split(separator: " ").count
            let wb = b.split(separator: " ").count
            let score: (Int) -> Int = { w in
                if (3...12).contains(w) { return 0 }
                return abs(w - 6)
            }
            return score(wa) < score(wb)
        }
        return ranked.first ?? parts[0]
    }

    private static func normalizeSayIt(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        if let first = t.first {
            t.replaceSubrange(t.startIndex...t.startIndex, with: String(first).uppercased())
        }
        return t
    }
}
