import SwiftUI
import SwiftData

/// Legacy phrasal chat — Репетитор → Словарь: суржик/транслит → EN + RU + actions.
struct SiteTutorLegacyView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var history: [SiteTutorTurn] = []
    @State private var draft = ""
    @State private var isBusy = false
    @State private var isListening = false
    @State private var errorMessage: String?
    @State private var capture = TimedSpeechCapture()
    @State private var speakReplies = true
    @State private var showNoKeyAlert = false
    @State private var libraryNote = ""
    @State private var voiceNote = ""
    @State private var loopSeed: TutorLoopSeed?
    @State private var selectedPhrasal: SiteTutorPhrasal?
    @State private var speaker: SpeechSpeaker?

    private struct TutorLoopSeed: Identifiable, Hashable {
        let id = UUID()
        let en: String
        let ru: String
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if history.isEmpty {
                            Text("Суржик / ломаный EN — или phrasal: «over», «phrasal take». Тап по phrasal → примеры со стройки.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                            HStack(spacing: 8) {
                                ForEach(["over", "phrasal take", "tray за basket"], id: \.self) { tip in
                                    Button(tip) { draft = tip }
                                        .buttonStyle(.bordered)
                                        .font(.caption)
                                }
                            }
                        }
                        ForEach(history) { turn in
                            Group {
                                if turn.role == .user {
                                    userBubble(turn.text)
                                } else if let reply = turn.reply {
                                    resultCard(reply)
                                } else {
                                    userBubble(turn.text)
                                }
                            }
                            .id(turn.id)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { NavChrome.dismissKeyboard() }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: history.count) { _, _ in
                    if let last = history.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            if !libraryNote.isEmpty {
                Text(libraryNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            if !voiceNote.isEmpty {
                let bad = voiceNote.contains("ошибка") || voiceNote.contains("выкл") || voiceNote.contains("системный")
                Text(voiceNote)
                    .font(bad ? .headline.weight(.bold) : .caption.weight(.semibold))
                    .foregroundStyle(bad ? Color.red : Color.orange)
                    .padding(.horizontal)
            }

            Divider()
            composer
                .padding()
                .background(.ultraThinMaterial)
        }
        .navigationTitle("Словарь phrasal")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $speakReplies) {
                    Image(systemName: speakReplies ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Озвучка ответов")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { NavChrome.dismissKeyboard() }
                    .fontWeight(.semibold)
            }
        }
        .alert("Нужен Gemini", isPresented: $showNoKeyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Вставь ключ Gemini в Настройках и включи toggle. Без ключа репетитор не разбирает суржик.")
        }
        .navigationDestination(item: $loopSeed) { seed in
            PhraseLoopView(
                seedPhrases: [(en: seed.en, ru: seed.ru)],
                backTitle: "К репетитору"
            )
        }
        .navigationDestination(item: $selectedPhrasal) { p in
            TutorPhrasalDetailView(phrasal: p)
        }
        .onAppear {
            if speaker == nil {
                speaker = SpeechSpeaker(settings: settings)
            }
        }
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                )
        }
    }

    private func resultCard(_ reply: SiteTutorReply) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("Ввод", reply.heardOrInput)
            labeled("EN", reply.en, emph: true)
            labeled("RU", reply.ru)
            if !reply.tipRu.isEmpty {
                labeled("Tip", reply.tipRu)
            }
            if !reply.phrasals.isEmpty {
                Text("Phrasals — тап для стройки")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                ForEach(reply.phrasals) { p in
                    Button {
                        selectedPhrasal = p
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.en).font(.subheadline.weight(.semibold))
                                if !p.ru.isEmpty {
                                    Text(p.ru).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            labeled("Say it", reply.sayIt, emph: true)

            HStack(spacing: 8) {
                Button {
                    speakEN(reply.en)
                } label: {
                    Label("Озвучить EN", systemImage: "speaker.wave.2.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button {
                    openTrainer(reply)
                } label: {
                    Label("В тренажёр", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    saveLibrary(reply)
                } label: {
                    Label("В библиотеку", systemImage: "books.vertical")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func labeled(_ title: String, _ value: String, emph: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(emph ? .title3.weight(.semibold) : .body)
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if isListening {
                VStack(spacing: 8) {
                    Text("\(capture.elapsedSeconds)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if !capture.partialText.isEmpty {
                        Text(capture.partialText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Готово") { capture.finish() }
                            .buttonStyle(.borderedProminent)
                        Button("Отмена", role: .cancel) {
                            capture.cancel()
                            isListening = false
                        }
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Суржик / термин / вопрос…", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isBusy)
                        .submitLabel(.done)
                        .onSubmit { NavChrome.dismissKeyboard() }

                    Button {
                        Task { await listen() }
                    } label: {
                        Image(systemName: "mic.fill")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(isBusy)

                    Button {
                        Task { await send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                    }
                    .disabled(isBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Actions

    private func listen() async {
        errorMessage = nil
        isListening = true
        let text = await capture.captureUntilStopped(localeId: "ru-RU", maxSeconds: 45)
        isListening = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            draft = trimmed
            await send()
        } else if !capture.errorMessage.isEmpty {
            errorMessage = capture.errorMessage
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard settings.geminiEnabledAndReady else {
            showNoKeyAlert = true
            errorMessage = "Нет ключа Gemini в Настройках"
            return
        }

        errorMessage = nil
        libraryNote = ""
        isBusy = true
        draft = ""
        history.append(SiteTutorTurn(role: .user, text: text))

        do {
            let reply = try await GeminiSiteCoachService.shared.tutorReply(history: history, userText: text)
            history.append(SiteTutorTurn(role: .tutor, text: reply.en, reply: reply))
            if speakReplies, !reply.en.isEmpty {
                speakEN(reply.en)
            }
        } catch {
            errorMessage = error.localizedDescription
            history.append(SiteTutorTurn(
                role: .tutor,
                text: "Не ответил: \(error.localizedDescription)",
                reply: nil
            ))
        }
        isBusy = false
    }

    private func speakEN(_ en: String) {
        speaker?.updateSettings(settings)
        voiceNote = "…"
        speaker?.speakEN(en) {
            voiceNote = speaker?.statusNote ?? ElevenLabsTTS.shared.lastStatusRU
        }
    }

    private func openTrainer(_ reply: SiteTutorReply) {
        let en = reply.sayIt.isEmpty ? reply.en : reply.sayIt
        guard !en.isEmpty else { return }
        let ru: String = {
            if !reply.sayItRu.isEmpty { return reply.sayItRu }
            if !reply.ru.isEmpty { return reply.ru }
            return en
        }()
        loopSeed = TutorLoopSeed(en: en, ru: ru)
    }

    private func saveLibrary(_ reply: SiteTutorReply) {
        let en = reply.sayIt.isEmpty ? reply.en : reply.sayIt
        guard !en.isEmpty else { return }
        _ = LibraryStore.add(
            context: modelContext,
            source: .manual,
            en: en,
            ru: reply.ru,
            tipRu: reply.tipRu,
            tag: .other,
            transcriptRaw: reply.heardOrInput
        )
        libraryNote = "В библиотеке: \(en)"
        CommandFeedback.acknowledged()
    }
}
