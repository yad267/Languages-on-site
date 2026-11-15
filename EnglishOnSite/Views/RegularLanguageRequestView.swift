import SwiftUI

/// Regular Language · Dialogues: type or speak a topic → up to 10 dialogue lessons.
struct RegularLanguageRequestView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// CEFR level from Regular Language → Диалоги → A1…C2.
    var preferredLevel: CEFRLevel = .a2
    var onCreated: ([Lesson]) -> Void

    @State private var request = ""
    @State private var status = ""
    @State private var isGenerating = false
    @State private var isListening = false
    @State private var errorMessage: String?
    @State private var showGeminiAlert = false
    @State private var generateTask: Task<Void, Never>?
    @State private var capture = TimedSpeechCapture()
    @State private var lastPack: [Lesson] = []

    var body: some View {
        Form {
            Section {
                Text("Уровень \(preferredLevel.rawValue). Напиши или скажи тему — например: «I want dating dialogues». До 10 диалогов на этом уровне.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Тема / запрос", text: $request, axis: .vertical)
                    .lineLimit(2...5)
                    .disabled(isGenerating || isListening)
                    .textInputAutocapitalization(.sentences)

                if isListening {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(capture.partialText.isEmpty ? "Слушаю…" : capture.partialText)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
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
                    HStack(spacing: 12) {
                        Button {
                            Task { await listenRequest() }
                        } label: {
                            Label("Голосом", systemImage: "mic.fill")
                        }
                        .disabled(isGenerating)

                        Spacer()

                        if isGenerating {
                            ProgressView()
                            Button("Отмена", role: .cancel) {
                                generateTask?.cancel()
                                generateTask = nil
                                isGenerating = false
                                status = ""
                            }
                        } else {
                            Button("Собрать до 10 уроков") { startGenerate() }
                                .buttonStyle(.borderedProminent)
                                .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                        }
                    }
                }
            } header: {
                Text("Regular Language · запрос")
            } footer: {
                Text(status.isEmpty
                     ? "Gemini вернёт до 10 коротких диалогов EN↔RU по теме (не стройка)."
                     : status)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }

            if !lastPack.isEmpty {
                Section("Готово · \(lastPack.count)") {
                    ForEach(lastPack) { lesson in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lesson.titleRu).font(.headline)
                            Text(lesson.sceneRu)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Regular Language")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Нужен Gemini", isPresented: $showGeminiAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Включи Gemini в Настройках, чтобы собрать диалоги по теме.")
        }
    }

    private func listenRequest() async {
        isListening = true
        status = "Скажи запрос → Готово"
        errorMessage = nil
        let text = await capture.captureUntilStopped(
            localeId: settings.rememberLocale.rawValue,
            maxSeconds: max(20, settings.translateDuration.rawValue)
        )
        isListening = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            status = "Не расслышал — скажи ещё раз или набери текстом"
            return
        }
        request = trimmed
        status = ""
    }

    private func startGenerate() {
        let raw = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count >= 2 else {
            errorMessage = "Введи или скажи тему"
            return
        }
        errorMessage = nil
        guard settings.geminiEnabledAndReady else {
            showGeminiAlert = true
            return
        }

        isGenerating = true
        status = "Собираю до 10 диалогов…"
        generateTask = Task {
            do {
                let lessons = try await GeminiSiteCoachService.shared.generateRegularDialogueLessons(
                    topic: raw,
                    cefr: preferredLevel.rawValue
                )
                try Task.checkCancellation()
                for lesson in lessons {
                    try LessonRepository.shared.saveUser(lesson)
                }
                await MainActor.run {
                    isGenerating = false
                    lastPack = lessons
                    status = "Готово · \(lessons.count) уроков"
                    onCreated(lessons)
                }
            } catch is CancellationError {
                await MainActor.run {
                    isGenerating = false
                    status = "Отменено"
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    status = ""
                    errorMessage = error.localizedDescription
                    if let ge = error as? GeminiLessonError {
                        switch ge {
                        case .noAPIKey, .geminiDisabled:
                            showGeminiAlert = true
                        default: break
                        }
                    }
                }
            }
        }
    }
}
