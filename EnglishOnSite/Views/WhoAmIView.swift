import SwiftUI

/// Capture “who I am at work” → structured `LearnerProfile`.
/// Voice accumulates into one monologue; save auto-builds the profile from the text.
struct WhoAmIView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// First-launch sheet — softer copy + skip.
    var isOnboarding: Bool = false
    /// After save — open first matching lesson (Home / onboarding).
    var onContinueToLesson: ((Lesson) -> Void)? = nil

    @State private var draftText = ""
    @State private var draft = LearnerProfile.default
    @State private var isListening = false
    @State private var capture = TimedSpeechCapture()
    @State private var didLoad = false
    @State private var showDetails = false
    @State private var voiceError = ""
    @State private var didJustSave = false

    private var store: LearnerProfileStore { .shared }

    private var trimmedIntro: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { trimmedIntro.count >= 8 || draft.role != .unknown }

    var body: some View {
        Form {
            Section {
                Text(isOnboarding
                     ? "Расскажи о себе голосом или текстом — кем работаешь, что делаешь, что крутишь. Подстроим уроки под тебя."
                     : "Introduction → твой профиль. Чем конкретнее монолог, тем точнее разделы и режим.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(
                    "Например: я электрик в Ирландии, вешаю лотки, режу металл, тяну кабель, хочу говорить на объекте",
                    text: $draftText,
                    axis: .vertical
                )
                .lineLimit(4...14)
                .disabled(isListening)
                .onChange(of: draftText) { _, newValue in
                    // Live re-parse while typing (cheap offline keywords).
                    if newValue.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 {
                        draft = LearnerProfile.infer(from: newValue, base: draft)
                    }
                }

                if isListening {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            ProgressView()
                            Text(capture.hitMaxCap ? "Лимит времени…" : "Слушаю… \(capture.elapsedSeconds)с")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if capture.secondsLeft > 0, capture.secondsLeft <= 30 {
                                Text("ещё \(capture.secondsLeft)с")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(livePreview)
                            .font(.body)
                            .foregroundStyle(livePreviewHasSpeech ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                        HStack {
                            Button("Готово") { capture.finish() }
                                .buttonStyle(.borderedProminent)
                            Button("Отмена", role: .cancel) {
                                capture.cancel()
                                isListening = false
                                voiceError = ""
                            }
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        Button {
                            Task { await listenAppend() }
                        } label: {
                            Label(
                                draftText.isEmpty ? "Голосом" : "Ещё голосом",
                                systemImage: "mic.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)

                        if !draftText.isEmpty {
                            Button("Очистить", role: .destructive) {
                                draftText = ""
                                draft = .default
                                voiceError = ""
                            }
                        }
                    }
                }

                if !voiceError.isEmpty {
                    Text(voiceError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Introduction")
            } footer: {
                Text("Русский — кириллицей. Английский сленг пишем как слышишь: джигсо, бенсоу, трей, контентмент (не латиницей и не переводом). Слова запоминаются в словарь. «Готово» → проверь → «Сохранить».")
            }

            if !draft.summaryChipsRU.isEmpty, trimmedIntro.count >= 8 || draft.role != .unknown {
                Section("Как поняла") {
                    Text(draft.summaryChipsRU.joined(separator: " · "))
                        .font(.subheadline.weight(.semibold))
                    Text("Режим: \(draft.role.preferredLearningMode.pickerLabel) · разделы подтянутся на Home")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !draft.tools.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Крепёж / инструмент из introduction")
                                .font(.caption.weight(.semibold))
                            ForEach(draft.tools.prefix(8)) { tool in
                                Text("• \(tool.raw) → \(tool.enCanonical)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                    DisclosureGroup("Уточнить вручную", isExpanded: $showDetails) {
                        Picker("Роль", selection: $draft.role) {
                            ForEach(LearnerRole.allCases) { role in
                                Text(role.titleRU).tag(role)
                            }
                        }
                        Text(draft.role.blurbRU)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Цель", selection: $draft.goal) {
                            ForEach(LearnerGoal.allCases) { g in
                                Text(g.titleRU).tag(g)
                            }
                        }
                        Picker("Уровень", selection: Binding(
                            get: { draft.cefr ?? .a2 },
                            set: { draft.cefr = $0 }
                        )) {
                            ForEach(CEFRLevel.allCases) { level in
                                Text(level.rawValue).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                        TextField("Рынок (IE / UK / …)", text: Binding(
                            get: { draft.market ?? "" },
                            set: { draft.market = $0.isEmpty ? nil : $0 }
                        ))
                        .textInputAutocapitalization(.characters)
                    }
                }
            }

            Section {
                Button {
                    saveAndContinue()
                } label: {
                    Text(isOnboarding ? "Сохранить и к первому уроку" : "Сохранить и подстроить")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)

                if isOnboarding {
                    Button("Позже") {
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                }

                if store.profile.isSet, !isOnboarding {
                    Button("Сбросить профиль", role: .destructive) {
                        draft = .default
                        draftText = ""
                        store.clear()
                    }
                }
            }
        }
        .navigationTitle(isOnboarding ? "Кто ты?" : "Кто я")
        .navigationBarTitleDisplayMode(.inline)
        .lexiconToast()
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            draft = store.profile
            draftText = store.profile.aboutRaw
            Task { await SpeechLexiconStore.shared.pullFromN8N() }
        }
    }

    private var livePreview: String {
        let live = capture.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if draftText.isEmpty { return live.isEmpty ? "Говори — текст появится здесь" : live }
        if live.isEmpty { return draftText }
        return draftText + " " + live
    }

    private var livePreviewHasSpeech: Bool {
        !capture.partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftText.isEmpty
    }

    /// Append a new take onto the existing introduction (never wipe).
    private func listenAppend() async {
        voiceError = ""
        isListening = true
        let profileTerms = draft.speechTerms
        let tools = draft.tools
        // Mixed RU+EN intro: server ASR + personal lexicon (трей/джигсо/бенсоу…).
        let text = await capture.captureUntilStopped(
            localeId: "mixed-ru-en",
            maxSeconds: 180,
            contextualStrings: LearnerSpeechLexicon.contextualStrings(
                profileTerms: profileTerms,
                tools: tools
            ),
            transcriptCorrector: { raw in
                LearnerSpeechLexicon.correctASR(raw, profileTerms: profileTerms)
            }
        )
        isListening = false
        let repaired = LearnerSpeechLexicon.correctASR(
            text,
            profileTerms: profileTerms
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if repaired.isEmpty {
            voiceError = capture.errorMessage.isEmpty
                ? "Не расслышала. Нажми «Голосом» ещё раз или допиши текстом."
                : capture.errorMessage
            return
        }
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftText = repaired
        } else {
            draftText = Self.joinIntro(existing: draftText, addition: repaired)
        }
        draft = LearnerProfile.infer(from: draftText, base: draft)
        // Auto-save new slang → Documents cache + n8n (source of truth).
        let known = draft.speechTerms
        Task {
            let added = await SpeechLexiconStore.shared.ingest(
                text: repaired,
                source: .introduction,
                knownProfileTerms: known
            )
            if !added.isEmpty {
                draft.speechTerms = SpeechLexiconStore.shared.spokenTerms
                draft.speechTermEntries = SpeechLexiconStore.shared.entries
            }
        }
        if capture.hitMaxCap {
            voiceError = "Достигли лимита записи — нажми «Ещё голосом», если нужно продолжить."
        }
    }

    private static func joinIntro(existing: String, addition: String) -> String {
        let a = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let aKey = a.lowercased()
        let bKey = b.lowercased()
        if bKey.hasPrefix(aKey) { return b }
        if aKey.hasSuffix(bKey) { return a }
        return a + " " + b
    }

    private func saveAndContinue() {
        guard canSave, !didJustSave else { return }
        didJustSave = true
        draft.aboutRaw = trimmedIntro
        if trimmedIntro.count >= 8 {
            draft = LearnerProfile.infer(from: trimmedIntro, base: draft)
            draft.aboutRaw = trimmedIntro
        }
        store.save(draft, applyLearningModeTo: settings)
        let lesson = store.firstRecommendedLesson()
        dismiss()
        if let lesson, let onContinueToLesson {
            // Let the sheet/nav settle, then jump straight into the lesson.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                onContinueToLesson(lesson)
            }
        }
    }
}
