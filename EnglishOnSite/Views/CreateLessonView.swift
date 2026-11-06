import SwiftUI

struct CreateLessonView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var onCreated: (Lesson) -> Void

    @State private var topic = ""
    @State private var status = ""
    @State private var isGenerating = false
    @State private var isListening = false
    @State private var errorMessage: String?
    @State private var showGeminiAlert = false
    @State private var showStubs = false
    @State private var generateTask: Task<Void, Never>?
    @State private var capture = TimedSpeechCapture()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Тема, например: прокладка копекса на чердаке", text: $topic, axis: .vertical)
                        .lineLimit(2...4)
                        .disabled(isGenerating || isListening)

                    if isListening {
                        VStack(spacing: 12) {
                            Text("\(capture.elapsedSeconds)")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("Слушаю тему… макс \(capture.secondsLeft) с")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if !capture.partialText.isEmpty {
                                Text(capture.partialText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                capture.finish()
                            } label: {
                                Text("Готово")
                                    .font(.headline.weight(.bold))
                                    .frame(maxWidth: .infinity, minHeight: 52)
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Отмена", role: .cancel) {
                                capture.cancel()
                                isListening = false
                                status = ""
                            }
                        }
                        .padding(.vertical, 8)
                    } else {
                        HStack(spacing: 12) {
                            Button {
                                Task { await listenTopic() }
                            } label: {
                                Label("Микрофон", systemImage: "mic.fill")
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
                                Button("Создать") { startCreate() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                            }
                        }
                    }
                } header: {
                    Text("Новый урок")
                } footer: {
                    Text(status.isEmpty ? "Gemini соберёт диалог EN↔RU по теме (Ireland site)." : status)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }

                if showStubs {
                    Section("Шаблоны без AI") {
                        ForEach(LessonRepository.stubTemplates()) { stub in
                            Button {
                                saveStubAndOpen(stub)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(stub.titleRu).font(.headline)
                                    Text(stub.sceneRu)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Создать урок")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        generateTask?.cancel()
                        dismiss()
                    } label: {
                        Text("Закрыть")
                            .font(.body.weight(.semibold))
                            .frame(minWidth: 72, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        generateTask?.cancel()
                        dismiss()
                    } label: {
                        Text("Готово")
                            .font(.body.weight(.bold))
                            .frame(minWidth: 72, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
            .alert("Нужен Gemini", isPresented: $showGeminiAlert) {
                Button("Шаблоны") { showStubs = true }
                Button("OK", role: .cancel) {}
            } message: {
                Text("Нужен Gemini в Настройках, чтобы создать урок")
            }
        }
    }

    private func startCreate() {
        let raw = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let extracted = LessonTopicParser.extractTopic(from: raw)
        guard extracted.count >= 2 else {
            errorMessage = "Введи тему урока"
            return
        }
        topic = extracted
        errorMessage = nil

        guard settings.geminiEnabledAndReady else {
            showGeminiAlert = true
            showStubs = true
            return
        }

        isGenerating = true
        status = "Собираю урок…"
        generateTask = Task {
            do {
                let lesson = try await GeminiSiteCoachService.shared.generateLesson(topic: extracted)
                try Task.checkCancellation()
                try LessonRepository.shared.saveUser(lesson)
                await MainActor.run {
                    isGenerating = false
                    status = "Готово"
                    onCreated(lesson)
                    dismiss()
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
                            showStubs = true
                        default: break
                        }
                    }
                }
            }
        }
    }

    private func listenTopic() async {
        isListening = true
        status = "Скажи тему → Готово"
        errorMessage = nil
        let text = await capture.captureUntilStopped(
            localeId: "ru-RU",
            maxSeconds: settings.translateDuration.rawValue
        )
        isListening = false

        let recognized: String
        if text.isEmpty {
            recognized = "урок про CCTV кабель"
            status = "Симулятор: демо-тема"
        } else {
            recognized = text
            status = ""
        }

        let extracted = LessonTopicParser.extractTopic(from: recognized)
        topic = extracted.isEmpty ? recognized : extracted

        if topic.count < 3 || isOnlyLessonCommand(recognized) {
            isListening = true
            status = "Тема? → Готово"
            let more = await capture.captureUntilStopped(
                localeId: "ru-RU",
                maxSeconds: settings.translateDuration.rawValue
            )
            isListening = false
            if !more.isEmpty {
                topic = LessonTopicParser.extractTopic(from: more)
                status = ""
            }
        }
    }

    private func isOnlyLessonCommand(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let cmds = settings.voiceCommands.newLesson + ["урок", "новый урок", "сделай урок"]
        return cmds.contains { t == $0 || t == "\($0):" || t == "\($0) про" }
    }

    private func saveStubAndOpen(_ stub: Lesson) {
        // Copy stub into user storage with unique id so it persists & is deletable
        let id = LessonTopicParser.makeUserLessonId(topic: stub.topicRaw ?? stub.titleRu)
        let copy = Lesson(
            id: id,
            titleRu: stub.titleRu.replacingOccurrences(of: " (шаблон)", with: ""),
            tags: stub.tags,
            sceneRu: stub.sceneRu,
            yourRole: stub.yourRole,
            partnerRole: stub.partnerRole,
            lines: stub.lines,
            sayToday: stub.sayToday,
            createdBy: "user_stub",
            topicRaw: stub.topicRaw
        )
        do {
            try LessonRepository.shared.saveUser(copy)
            onCreated(copy)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
