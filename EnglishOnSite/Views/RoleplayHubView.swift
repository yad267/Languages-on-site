import SwiftUI
import SwiftData

struct RoleplayHubView: View {
    var body: some View {
        NavigationStack {
            RoleplayHubContent()
        }
    }
}

/// Embedded under Репетитор (B14 — Roleplay not a root tab).
struct RoleplayHubEmbeddedView: View {
    var body: some View {
        RoleplayHubContent()
    }
}

private struct RoleplayHubContent: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @State private var repo = RoleplayRepository.shared
    @State private var showImport = false
    @State private var showAddPhrase = false
    @State private var trainScript: RoleplayScript?

    @State private var brief = ""
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var isListening = false
    @State private var preview: RoleplayScript?
    @State private var workTask: Task<Void, Never>?
    @State private var capture = TimedSpeechCapture()
    @State private var speaker: SpeechSpeaker?
    @State private var isPlayingAll = false
    @State private var phrasesSavedNote = ""

    var body: some View {
        List {
                Section {
                    TextEditor(text: $brief)
                        .frame(minHeight: 100)
                        .font(.body)
                        .disabled(isWorking || isListening)
                        .accessibilityLabel("Опиши, какой диалог нужен")

                    HStack(spacing: 12) {
                        Button {
                            Task { await toggleMic() }
                        } label: {
                            Label(
                                isListening ? "Стоп" : "Сказать",
                                systemImage: isListening ? "stop.circle.fill" : "mic.fill"
                            )
                        }
                        .disabled(isWorking)

                        Spacer()

                        if isWorking {
                            ProgressView()
                            Button("Отмена", role: .cancel) {
                                workTask?.cancel()
                                workTask = nil
                                isWorking = false
                                status = ""
                            }
                        } else {
                            Button("Сделать диалог") { startGenerate() }
                                .buttonStyle(.borderedProminent)
                                .disabled(
                                    brief.trimmingCharacters(in: .whitespacesAndNewlines).count < 4
                                        || isListening
                                )
                        }
                    }
                } header: {
                    Text("Опиши, какой диалог нужен")
                } footer: {
                    Text(status.isEmpty
                         ? "Свои слова RU/EN — без Supervisor:. Пример: «tray basket lay down» или «give me a hand with the Unistrut»."
                         : status)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }

                if let preview {
                    Section("Диалог · \(preview.lines.count) реплик") {
                        Text(preview.titleRu)
                            .font(.headline)
                        Text(preview.sceneRu)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button {
                                playAll(preview)
                            } label: {
                                Label(isPlayingAll ? "Стоп" : "Слушать", systemImage: isPlayingAll ? "stop.fill" : "speaker.wave.2.fill")
                            }
                            .buttonStyle(.bordered)

                            Button("Сохранить диалог") {
                                saveDialog(preview)
                            }
                            .buttonStyle(.borderedProminent)

                            Button("В Мои фразы") {
                                saveAllPhrases(preview)
                            }
                            .buttonStyle(.bordered)
                        }

                        if !phrasesSavedNote.isEmpty {
                            Text(phrasesSavedNote)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        ForEach(preview.lines) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.role)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                Text(line.en)
                                    .font(.body.weight(.semibold))
                                Text(line.ru)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .contextMenu {
                                Button("В Мои фразы") {
                                    saveOnePhrase(line)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showImport = true
                    } label: {
                        Label("Импорт Name: / файл", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        showAddPhrase = true
                    } label: {
                        Label("Одна фраза → Мои фразы", systemImage: "text.badge.plus")
                    }
                } footer: {
                    Text("Если уже есть Supervisor: / Installer: — импорт разберёт как раньше.")
                }

                Section("Сохранённые диалоги") {
                    if repo.scripts.isEmpty {
                        Text("Пока пусто")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(repo.scripts) { script in
                            NavigationLink(value: script) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(script.titleRu)
                                        .font(.headline)
                                    Text("\(script.lines.count) реплик · \(script.roleNames.joined(separator: " / "))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for i in indexSet {
                                let id = repo.scripts[i].id
                                try? repo.delete(id: id)
                            }
                        }
                    }
                }
            }
        .navigationTitle("Roleplay")
        .navigationDestination(for: RoleplayScript.self) { script in
            RoleplayLoopView(script: script)
        }
        .navigationDestination(item: $trainScript) { script in
            RoleplayLoopView(script: script)
        }
        .sheet(isPresented: $showImport) {
            ImportRoleplayView { script in
                repo.reload()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    trainScript = script
                }
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddPhrase) {
            AddMyPhraseView(source: .importText)
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            repo.reload()
            if speaker == nil {
                speaker = SpeechSpeaker(settings: settings)
            }
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-EOSRoleplayInjectTray"), preview == nil, !isWorking {
                brief = "tray basket lay down workplace"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    startGenerate()
                }
            }
            #endif
        }
        .onDisappear {
            capture.cancel()
            speaker?.stop()
            workTask?.cancel()
        }
    }

    private func startGenerate() {
        errorMessage = nil
        phrasesSavedNote = ""
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return }
        isWorking = true
        if RoleplayParserService.looksLikeNamedDialogue(trimmed) {
            status = settings.geminiEnabledAndReady ? "Разбираю Name:…" : "Локальный парсер…"
        } else {
            status = settings.geminiEnabledAndReady ? "Gemini пишет диалог…" : "Локальный черновик…"
        }
        workTask = Task {
            do {
                let script = try await RoleplayParserService.parse(rawText: trimmed, settings: settings)
                guard !Task.isCancelled else { return }
                preview = script
                status = "Готово · \(script.lines.count) реплик"
                isWorking = false
                workTask = nil
                // Prefetch after UI unlock (Listen).
                for line in script.lines.prefix(4) {
                    await ElevenLabsTTS.shared.prefetchToDisk(text: line.en, lang: .en, settings: settings)
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                status = ""
                preview = nil
                isWorking = false
                workTask = nil
            }
        }
    }

    private func toggleMic() async {
        if isListening {
            capture.finish()
            return
        }
        errorMessage = nil
        isListening = true
        status = "Слушаю…"
        let text = await capture.captureUntilStopped(
            localeId: "ru-RU",
            maxSeconds: 45,
            contextualStrings: [
                "tray", "basket", "lay down", "clamp", "bolt", "Unistrut",
                "containment", "zebs", "диалог", "реплик",
            ]
        )
        isListening = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            status = capture.errorMessage.isEmpty ? "Не расслышал — ещё раз" : capture.errorMessage
            return
        }
        if LanguageDetect.classify(trimmed) == .garbage {
            status = "Не расслышал — скажи ещё раз"
            return
        }
        brief = trimmed
        status = "Готово к «Сделать диалог»"
    }

    private func playAll(_ script: RoleplayScript) {
        if isPlayingAll {
            speaker?.stop()
            isPlayingAll = false
            return
        }
        speaker?.updateSettings(settings)
        let parts = script.lines.map { (text: $0.en, english: true) }
        isPlayingAll = true
        speaker?.speakSequence(parts) {
            isPlayingAll = false
        }
    }

    private func saveDialog(_ script: RoleplayScript) {
        do {
            try RoleplayRepository.shared.save(script)
            repo.reload()
            status = "Сохранено · можно тренировать"
            trainScript = script
        } catch {
            errorMessage = "Не сохранил: \(error.localizedDescription)"
        }
    }

    private func saveOnePhrase(_ line: RoleplayLine) {
        let item = LibraryStore.add(
            context: modelContext,
            source: .roleplay,
            en: line.en,
            ru: line.ru,
            tipRu: line.tipRu ?? "",
            tag: .tools,
            transcriptRaw: brief,
            itemType: .sentence
        )
        phrasesSavedNote = "В Мои фразы: \(line.en)"
        Task { await bindLibraryAudio(item) }
    }

    private func saveAllPhrases(_ script: RoleplayScript) {
        var saved: [LibraryItem] = []
        for line in script.lines {
            let item = LibraryStore.add(
                context: modelContext,
                source: .roleplay,
                en: line.en,
                ru: line.ru,
                tipRu: line.tipRu ?? "",
                tag: .tools,
                transcriptRaw: brief,
                itemType: .sentence
            )
            saved.append(item)
        }
        phrasesSavedNote = "Все \(script.lines.count) реплик → Мои фразы"
        Task {
            for item in saved.prefix(8) {
                await bindLibraryAudio(item)
            }
        }
    }

    private func bindLibraryAudio(_ item: LibraryItem) async {
        await ElevenLabsTTS.shared.prefetchToDisk(text: item.en, lang: .en, settings: settings)
        let params = settings.elVoiceParams(for: .en)
        let voice = SiteVoiceLang.en.voiceId
        let cache = ElevenLabsAudioCache.fileURL(text: item.en, voice: voice, params: params)
        let preferred = item.audioFileName ?? "\(item.id.uuidString).mp3"
        if let name = LibraryAudioStore.bindFromCacheURL(cache, preferredName: preferred) {
            item.audioFileName = name
            item.audioCacheKey = ElevenLabsAudioCache.cacheKey(text: item.en, voice: voice, params: params)
            try? modelContext.save()
        }
    }
}
