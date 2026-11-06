import SwiftUI
import SwiftData

/// B17: one phrase (RU or EN, voice or text) → canon → Мои фразы.
struct AddMyPhraseView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var initialText: String = ""
    var source: LibrarySource = .manual
    var phrasalHint: String? = nil
    var onSaved: ((LibraryItem) -> Void)? = nil

    @State private var draft = ""
    @State private var canon: CanonPhrase?
    @State private var note = ""
    @State private var isWorking = false
    @State private var isListening = false
    @State private var capture = TimedSpeechCapture()
    @State private var speaker: SpeechSpeaker?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Фраза RU или EN", text: $draft, axis: .vertical)
                        .lineLimit(2...6)
                        .disabled(isWorking || isListening)

                    HStack {
                        Button {
                            Task { await toggleMic() }
                        } label: {
                            Label(isListening ? "Стоп" : "Сказать", systemImage: isListening ? "stop.circle.fill" : "mic.fill")
                        }
                        .disabled(isWorking)

                        Spacer()

                        Button("Канон") { Task { await runCanon() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(isWorking || isListening
                                      || draft.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                    }
                } header: {
                    Text("Ввод")
                } footer: {
                    Text(note.isEmpty
                         ? "Одна фраза или несколько строк. Имя: не обязательно. Gemini сделает правильный разговорный EN."
                         : note)
                }

                if let canon {
                    Section("Канон") {
                        Text(canon.en)
                            .font(.title3.weight(.bold))
                        Text(canon.ru)
                            .foregroundStyle(.secondary)
                        if !canon.tipRu.isEmpty {
                            Text(canon.tipRu).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("▶ EN") {
                                speaker?.updateSettings(settings)
                                speaker?.speakEN(canon.en)
                            }
                            .buttonStyle(.bordered)
                            Button("Сохранить") { save(canon) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .navigationTitle("Добавить фразу")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NavChrome.close(dismiss: dismiss)
                }
            }
            .onAppear {
                speaker = SpeechSpeaker(settings: settings)
                if draft.isEmpty, !initialText.isEmpty { draft = initialText }
            }
            .onDisappear {
                capture.cancel()
                speaker?.stop()
            }
        }
    }

    private func toggleMic() async {
        if isListening {
            capture.finish()
            return
        }
        note = ""
        canon = nil
        draft = "" // B12-style: fresh attempt
        isListening = true
        let enLocale = settings.rememberLocale == .enGB ? "en-GB" : "en-IE"
        // Prefer RU mic for empty field (site workers); EN if draft was Cyrillic before clear — use RU.
        let locale = "ru-RU"
        _ = enLocale
        let text = await capture.captureUntilStopped(localeId: locale, maxSeconds: 45, contextualStrings: [])
        isListening = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = trimmed
        if trimmed.isEmpty {
            note = capture.errorMessage.isEmpty ? "Не расслышал — ещё раз" : capture.errorMessage
            return
        }
        if LanguageDetect.classify(trimmed) == .garbage {
            note = "Не расслышал — скажи ещё раз"
            draft = ""
            return
        }
        await runCanon()
    }

    private func runCanon() async {
        let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count >= 2 else { return }
        if LanguageDetect.classify(raw) == .garbage {
            note = "Не расслышал — скажи ещё раз"
            return
        }
        isWorking = true
        note = settings.geminiEnabledAndReady ? "Gemini делает канон…" : "Офлайн…"
        defer { isWorking = false }
        do {
            let c = try await MyPhraseCanonService.canonize(
                raw: raw,
                settings: settings,
                phrasalHint: phrasalHint
            )
            canon = c
            note = c.viaGemini ? "Канон готов" : "Офлайн-канон"
            // Warm EN audio for evening ▶
            await ElevenLabsTTS.shared.prefetchToDisk(text: c.en, lang: .en, settings: settings)
        } catch {
            note = error.localizedDescription
            canon = nil
        }
    }

    private func save(_ c: CanonPhrase) {
        let item = LibraryStore.add(
            context: modelContext,
            source: source,
            en: c.en,
            ru: c.ru,
            tipRu: c.tipRu,
            tag: .other,
            transcriptRaw: draft,
            itemType: .myPhrase
        )
        Task {
            await ElevenLabsTTS.shared.prefetchToDisk(text: c.en, lang: .en, settings: settings)
            let params = settings.elVoiceParams(for: .en)
            let voice = SiteVoiceLang.en.voiceId
            let cache = ElevenLabsAudioCache.fileURL(text: c.en, voice: voice, params: params)
            let preferred = "\(item.id.uuidString).mp3"
            if let name = LibraryAudioStore.bindFromCacheURL(cache, preferredName: preferred) {
                item.audioFileName = name
                item.audioCacheKey = ElevenLabsAudioCache.cacheKey(text: c.en, voice: voice, params: params)
                try? modelContext.save()
            }
        }
        onSaved?(item)
        dismiss()
    }
}
