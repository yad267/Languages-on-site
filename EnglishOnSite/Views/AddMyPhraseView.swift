import SwiftUI
import SwiftData

/// B17: one phrase (RU or EN, voice or keyboard) → canon → Мои фразы.
/// Mic locale follows phrase language (draft / last STT); keyboard Save = canon + library.
struct AddMyPhraseView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var initialText: String = ""
    var source: LibrarySource = .manual
    var phrasalHint: String? = nil
    var onSaved: ((LibraryItem) -> Void)? = nil
    /// When true (voice path), save as soon as canon is ready.
    var autoSaveAfterVoice: Bool = true

    @State private var draft = ""
    @State private var canon: CanonPhrase?
    @State private var note = ""
    @State private var isWorking = false
    @State private var isListening = false
    @State private var didAutoSave = false
    @State private var capture = TimedSpeechCapture()
    @State private var speaker: SpeechSpeaker?
    @State private var listenTask: Task<Void, Never>?
    /// Last known phrase language for empty-draft mic (RU ↔ EN).
    @State private var lastPhraseLang: SpeechLangKind = .russian
    @State private var activeMicLocale = "ru-RU"
    @FocusState private var draftFocused: Bool

    var body: some View {
        NavigationStack {
            // ScrollView (not Form): Form rows often swallow mic taps / ignore actions.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Клавиатура или микрофон")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    TextField("Напиши фразу на русском или EN…", text: $draft, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                        .focused($draftFocused)
                        .disabled(isWorking || isListening)
                        .accessibilityLabel("Ввод с клавиатуры")
                        .onChange(of: draft) { _, newValue in
                            rememberLang(from: newValue)
                        }

                    HStack(spacing: 12) {
                        Button {
                            draftFocused = false
                            toggleMic()
                        } label: {
                            Label(
                                isListening ? "Стоп" : "Сказать",
                                systemImage: isListening ? "stop.circle.fill" : "mic.fill"
                            )
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isListening ? .red : .accentColor)
                        .disabled(isWorking)
                        .accessibilityLabel(isListening ? "Стоп" : "Сказать голосом")

                        Button {
                            draftFocused = false
                            Task { await saveFromKeyboard() }
                        } label: {
                            Text("Сохранить")
                                .font(.headline.weight(.bold))
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            isWorking || isListening
                                || draft.trimmingCharacters(in: .whitespacesAndNewlines).count < 2
                        )
                        .accessibilityLabel("Сохранить с клавиатуры")
                    }

                    Button {
                        draftFocused = false
                        Task { await runCanon(autoSave: false) }
                    } label: {
                        Text("Только канон (без сохранения)")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        isWorking || isListening
                            || draft.trimmingCharacters(in: .whitespacesAndNewlines).count < 2
                    )

                    if isListening {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(listeningHint)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(capture.partialText.isEmpty ? "…" : capture.partialText)
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            HStack {
                                Button("Готово") { capture.finish() }
                                    .buttonStyle(.borderedProminent)
                                Button("Отмена", role: .cancel) {
                                    listenTask?.cancel()
                                    capture.cancel()
                                    isListening = false
                                    note = ""
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                    }

                    if !note.isEmpty {
                        Text(note)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(didAutoSave ? .green : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let canon {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("EN")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            Text(canon.en)
                                .font(.title3.weight(.bold))
                                .fixedSize(horizontal: false, vertical: true)

                            Text("RU")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            Text(canon.ru)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if !canon.tipRu.isEmpty {
                                Text(canon.tipRu)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            HStack(spacing: 10) {
                                Button("▶ EN") {
                                    speaker?.updateSettings(settings)
                                    speaker?.speakEN(canon.en)
                                }
                                .buttonStyle(.bordered)

                                if !didAutoSave {
                                    Button("Сохранить") { save(canon) }
                                        .buttonStyle(.borderedProminent)
                                } else {
                                    Button("Ещё фраза") {
                                        draft = ""
                                        self.canon = nil
                                        note = ""
                                        didAutoSave = false
                                        draftFocused = true
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.accentColor.opacity(0.08))
                        )
                    }

                    Text("Микрофон сам выбирает RU или EN по языку текста в поле (или по прошлой фразе). Клавиатура: набери → Сохранить.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Добавить фразу")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NavChrome.close(dismiss: dismiss)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Сохранить") {
                        draftFocused = false
                        Task { await saveFromKeyboard() }
                    }
                    .fontWeight(.semibold)
                    .disabled(
                        isWorking || isListening
                            || draft.trimmingCharacters(in: .whitespacesAndNewlines).count < 2
                    )
                }
            }
            .onAppear {
                speaker = SpeechSpeaker(settings: settings)
                if draft.isEmpty, !initialText.isEmpty {
                    draft = initialText
                    rememberLang(from: initialText)
                }
            }
            .onDisappear {
                listenTask?.cancel()
                capture.cancel()
                speaker?.stop()
            }
        }
    }

    private var listeningHint: String {
        if activeMicLocale.lowercased().hasPrefix("en") {
            return "Слушаю… говори по-английски (\(activeMicLocale))"
        }
        return "Слушаю… говори по-русски (\(activeMicLocale))"
    }

    private var englishSpeechLocale: String {
        settings.rememberLocale == .enGB ? "en-GB" : "en-IE"
    }

    /// ASR locale from draft script; empty draft → last known phrase language.
    private func micLocaleId(forDraft text: String) -> String {
        switch LanguageDetect.classify(text) {
        case .russian:
            return "ru-RU"
        case .english:
            return englishSpeechLocale
        case .empty, .garbage:
            switch lastPhraseLang {
            case .english:
                return englishSpeechLocale
            case .russian, .empty, .garbage:
                return "ru-RU"
            }
        }
    }

    private func rememberLang(from text: String) {
        switch LanguageDetect.classify(text) {
        case .russian:
            lastPhraseLang = .russian
        case .english:
            lastPhraseLang = .english
        case .empty, .garbage:
            break
        }
    }

    private func toggleMic() {
        if isListening {
            capture.finish()
            return
        }
        listenTask?.cancel()
        note = ""
        canon = nil
        didAutoSave = false
        // Keep typed draft — locale follows its language (or lastPhraseLang if empty).
        let locale = micLocaleId(forDraft: draft)
        activeMicLocale = locale
        isListening = true
        listenTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let text = await capture.captureUntilStopped(
                localeId: locale,
                maxSeconds: 45,
                contextualStrings: []
            )
            guard !Task.isCancelled else { return }
            isListening = false
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                note = capture.errorMessage.isEmpty ? "Не расслышал — ещё раз" : capture.errorMessage
                return
            }
            if LanguageDetect.classify(trimmed) == .garbage {
                note = "Не расслышал — скажи ещё раз (язык: \(locale))"
                return
            }
            draft = trimmed
            rememberLang(from: trimmed)
            await runCanon(autoSave: autoSaveAfterVoice)
        }
    }

    /// Keyboard primary path: canonize then save into Мои фразы.
    private func saveFromKeyboard() async {
        await runCanon(autoSave: true)
        if canon != nil, didAutoSave {
            note = "Сохранено в Мои фразы"
        }
    }

    private func runCanon(autoSave: Bool) async {
        let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count >= 2 else { return }
        if LanguageDetect.classify(raw) == .garbage {
            note = "Не расслышал — скажи ещё раз"
            return
        }
        rememberLang(from: raw)
        isWorking = true
        note = settings.geminiEnabledAndReady ? "Перевожу…" : "Офлайн-канон…"
        defer { isWorking = false }
        do {
            let c = try await MyPhraseCanonService.canonize(
                raw: raw,
                settings: settings,
                phrasalHint: phrasalHint
            )
            canon = c
            if c.sourceIsRussian, !raw.isEmpty {
                draft = raw
            }
            note = c.viaGemini ? "Готово" : "Офлайн-канон"
            await ElevenLabsTTS.shared.prefetchToDisk(text: c.en, lang: .en, settings: settings)
            if autoSave {
                save(c, dismissAfter: false)
                note = "Сохранено в Мои фразы"
                didAutoSave = true
            }
        } catch {
            note = error.localizedDescription
            canon = nil
        }
    }

    private func save(_ c: CanonPhrase, dismissAfter: Bool = true) {
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
        if dismissAfter {
            dismiss()
        }
    }
}
