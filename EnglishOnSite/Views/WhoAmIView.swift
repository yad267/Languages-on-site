import SwiftUI

/// Capture “who I am at work” → structured `LearnerProfile`.
/// Pitfalls handled: no Gemini required; confirm chips before save; locales stored for future i18n.
struct WhoAmIView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var draftText = ""
    @State private var draft = LearnerProfile.default
    @State private var isListening = false
    @State private var capture = TimedSpeechCapture()
    @State private var didLoad = false

    private var store: LearnerProfileStore { .shared }

    var body: some View {
        Form {
            Section {
                Text("Расскажи, кем работаешь и зачем английский. Подстроим разделы и режим (Onsite / Regular). Позже тот же профиль пойдёт в мультиязычный UI.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("О себе") {
                TextField("Например: электрик на стройке в Ирландии, кручу лотки, ищу работу, A2", text: $draftText, axis: .vertical)
                    .lineLimit(3...8)
                    .disabled(isListening)

                if isListening {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(capture.partialText.isEmpty ? "Слушаю…" : capture.partialText)
                            .font(.subheadline.weight(.semibold))
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
                    HStack {
                        Button {
                            Task { await listen() }
                        } label: {
                            Label("Голосом", systemImage: "mic.fill")
                        }
                        Spacer()
                        Button("Распознать") { reparse() }
                            .buttonStyle(.bordered)
                            .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                    }
                }
            }

            Section("Профиль (проверь)") {
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

            Section("Языки (задел под мульти)") {
                Picker("Интерфейс", selection: $draft.uiLocale) {
                    ForEach(AppLocaleCode.allCases) { Text($0.titleNative).tag($0) }
                }
                Picker("Подсказки", selection: $draft.explainLocale) {
                    ForEach(AppLocaleCode.allCases) { Text($0.titleNative).tag($0) }
                }
                Picker("Учу", selection: $draft.targetLocale) {
                    ForEach(AppLocaleCode.allCases) { Text($0.titleNative).tag($0) }
                }
                Text("Сейчас контент EN↔RU; поля локалей уже в профиле, чтобы не ломать модель при i18n.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !draft.summaryChipsRU.isEmpty {
                Section("Итог") {
                    Text(draft.summaryChipsRU.joined(separator: " · "))
                        .font(.subheadline.weight(.semibold))
                    Text("Режим по роли: \(draft.role.preferredLearningMode.pickerLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Сохранить и подстроить") {
                    draft.aboutRaw = draftText
                    store.save(draft, applyLearningModeTo: settings)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.role == .unknown && draftText.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)

                if store.profile.isSet {
                    Button("Сбросить профиль", role: .destructive) {
                        draft = .default
                        draftText = ""
                        store.clear()
                    }
                }
            }
        }
        .navigationTitle("Кто я")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            draft = store.profile
            draftText = store.profile.aboutRaw
        }
    }

    private func reparse() {
        draft = LearnerProfile.infer(from: draftText, base: draft)
    }

    private func speechLocaleId(for code: AppLocaleCode) -> String {
        // Pitfall: STT locale ≠ UI strings; use device-supported BCP-47 ids.
        switch code {
        case .ru: return "ru-RU"
        case .uk: return "uk-UA"
        case .pl: return "pl-PL"
        case .en: return "en-IE"
        }
    }

    private func listen() async {
        isListening = true
        let text = await capture.captureUntilStopped(
            localeId: speechLocaleId(for: draft.uiLocale),
            maxSeconds: 45
        )
        isListening = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draftText = trimmed
        reparse()
    }
}
