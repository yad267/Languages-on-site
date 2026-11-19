import PhotosUI
import SwiftUI
import UIKit

/// Inbox: topic / voice / photo OCR / paste text → Gemini lesson → auto category folder.
struct CreateLessonView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var onCreated: (Lesson) -> Void

    @State private var topic = ""
    @State private var pasteText = ""
    @State private var status = ""
    @State private var isGenerating = false
    @State private var isListening = false
    @State private var errorMessage: String?
    @State private var showGeminiAlert = false
    @State private var showStubs = false
    @State private var showCamera = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var generateTask: Task<Void, Never>?
    @State private var capture = TimedSpeechCapture()
    @State private var catalog = UserLessonCatalogStore.shared
    @State private var predictedFolder = TopicCategoryClassifier.classify("")

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Что угодно: «я электрик», «отпуск», «документы Intravel»…",
                        text: $topic,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                    .disabled(isGenerating || isListening)
                    .onChange(of: topic) { _, newValue in
                        predictedFolder = TopicCategoryClassifier.classify(newValue)
                    }

                    if isListening {
                        listeningBlock
                    } else {
                        inputButtons
                    }

                    Label(
                        "Папка: \(predictedFolder.titleRu) · \(predictedFolder.titleEn)",
                        systemImage: "folder.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Новый урок")
                } footer: {
                    Text(status.isEmpty
                         ? "Профиль «Кто я» влияет на все уроки. Папка создаётся сама по теме."
                         : status)
                }

                Section {
                    TextField("Вставь текст документа или диалога…", text: $pasteText, axis: .vertical)
                        .lineLimit(4...12)
                        .disabled(isGenerating)
                    Button {
                        startCreate(from: pasteText, kind: .text)
                    } label: {
                        Label("Сделать урок из текста", systemImage: "doc.text.fill")
                    }
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 || isGenerating)
                } header: {
                    Text("Текст")
                }

                if !catalog.categories.isEmpty {
                    Section("Мои папки") {
                        ForEach(catalog.categories) { cat in
                            NavigationLink {
                                UserCategoryLessonsView(category: cat)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cat.titleRu).font(.headline)
                                        Text(cat.titleEn)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(catalog.lessons(in: cat.id, from: .shared).count)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
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
                            Button { saveStubAndOpen(stub) } label: {
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
                    Button("Закрыть") {
                        generateTask?.cancel()
                        dismiss()
                    }
                }
            }
            .alert("Нужен Gemini", isPresented: $showGeminiAlert) {
                Button("Шаблоны") { showStubs = true }
                Button("OK", role: .cancel) {}
            } message: {
                Text("Нужен Gemini в Настройках, чтобы создать урок")
            }
            .sheet(isPresented: $showCamera) {
                CreateLessonCameraPicker { image in
                    showCamera = false
                    guard let image else { return }
                    Task { await createFromPhoto(image) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: pickedItem) { _, item in
                Task { await loadPicked(item) }
            }
            .navigationDestination(for: Lesson.self) { lesson in
                PlayerView(lesson: lesson)
            }
            .lexiconToast()
            .onAppear {
                catalog.sync(from: LessonRepository.shared.lessons)
                Task { await SpeechLexiconStore.shared.pullFromN8N() }
            }
        }
    }

    @ViewBuilder
    private var listeningBlock: some View {
        VStack(spacing: 12) {
            Text("\(capture.elapsedSeconds)")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("Слушаю… макс \(capture.secondsLeft) с")
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
    }

    @ViewBuilder
    private var inputButtons: some View {
        HStack(spacing: 10) {
            Button {
                Task { await listenTopic() }
            } label: {
                Label("Голос", systemImage: "mic.fill")
            }
            .disabled(isGenerating)

            Button {
                showCamera = true
            } label: {
                Label("Фото", systemImage: "camera.fill")
            }
            .disabled(isGenerating)

            PhotosPicker(selection: $pickedItem, matching: .images) {
                Image(systemName: "photo.on.rectangle")
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
                Button("Создать") { startCreate(from: topic, kind: .topic) }
                    .buttonStyle(.borderedProminent)
                    .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            }
        }
    }

    private func startCreate(from rawInput: String, kind: UserLessonSourceKind) {
        let raw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let extracted = kind == .topic ? LessonTopicParser.extractTopic(from: raw) : raw
        guard extracted.count >= 2 else {
            errorMessage = kind == .text ? "Вставь текст подлиннее" : "Введи тему урока"
            return
        }
        if kind == .topic { topic = extracted }
        errorMessage = nil

        guard settings.geminiEnabledAndReady else {
            showGeminiAlert = true
            showStubs = true
            return
        }

        let hit = TopicCategoryClassifier.classify(extracted)
        predictedFolder = hit
        let lexSource: SpeechTermSource = {
            switch kind {
            case .photo: return .photo
            case .text: return .document
            case .topic: return .topic
            }
        }()
        Task {
            _ = await SpeechLexiconStore.shared.ingest(
                text: extracted,
                source: lexSource,
                knownProfileTerms: LearnerProfileStore.shared.profile.speechTerms
            )
        }
        isGenerating = true
        status = "Собираю урок → \(hit.titleRu)…"
        generateTask = Task {
            do {
                var lesson = try await GeminiSiteCoachService.shared.generateLesson(
                    topic: extracted,
                    profile: LearnerProfileStore.shared.profile,
                    sourceKind: kind,
                    categoryHint: hit
                )
                try Task.checkCancellation()
                let category = UserLessonCatalogStore.shared.ensureCategory(forText: extracted)
                lesson = Lesson(
                    id: lesson.id,
                    titleRu: lesson.titleRu,
                    titleEn: lesson.titleEn,
                    tags: lesson.tags,
                    sceneRu: lesson.sceneRu,
                    yourRole: lesson.yourRole,
                    partnerRole: lesson.partnerRole,
                    cards: lesson.cards,
                    lines: lesson.lines,
                    sayToday: lesson.sayToday,
                    createdBy: lesson.createdBy,
                    topicRaw: lesson.topicRaw,
                    order: lesson.order,
                    cefr: lesson.cefr,
                    categoryId: category.id,
                    categoryTitleRu: category.titleRu,
                    sourceKind: kind.rawValue
                )
                try LessonRepository.shared.saveUser(lesson)
                UserLessonCatalogStore.shared.assign(lessonId: lesson.id, category: category)
                await MainActor.run {
                    isGenerating = false
                    status = "В папке «\(category.titleRu)»"
                    catalog = UserLessonCatalogStore.shared
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
                    errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? "Не получилось собрать урок. Проверь сеть и попробуй короче."
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
            localeId: "mixed-ru-en",
            maxSeconds: max(30, settings.translateDuration.rawValue),
            contextualStrings: LearnerSpeechLexicon.contextualStrings(
                profileTerms: LearnerProfileStore.shared.profile.speechTerms
            ),
            transcriptCorrector: { raw in
                LearnerSpeechLexicon.correctASR(
                    raw,
                    profileTerms: LearnerProfileStore.shared.profile.speechTerms
                )
            }
        )
        isListening = false
        if text.isEmpty {
            errorMessage = capture.errorMessage.isEmpty
                ? "Не расслышала тему. Нажми голос ещё раз или набери текстом."
                : capture.errorMessage
            status = ""
            return
        }
        let extracted = LessonTopicParser.extractTopic(from: text)
        topic = extracted.isEmpty ? text : extracted
        predictedFolder = TopicCategoryClassifier.classify(topic)
        status = ""
        Task {
            _ = await SpeechLexiconStore.shared.ingest(
                text: topic,
                source: .topic,
                knownProfileTerms: LearnerProfileStore.shared.profile.speechTerms
            )
        }
    }

    private func loadPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = "Не открыла фото"
                return
            }
            await createFromPhoto(image)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createFromPhoto(_ image: UIImage) async {
        errorMessage = nil
        status = "Читаю текст с фото…"
        isGenerating = true
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            isGenerating = false
            errorMessage = "Не сжалось фото"
            status = ""
            return
        }
        do {
            let ocr: String
            do {
                ocr = try await MLKitOfflineTranslateService.shared.recognizeOCR(imageJPEG: jpeg)
            } catch {
                // Fallback: ask Gemini vision identify if offline OCR empty.
                throw error
            }
            pasteText = ocr
            predictedFolder = TopicCategoryClassifier.classify(ocr)
            isGenerating = false
            status = "OCR готов — собираю урок…"
            startCreate(from: ocr, kind: .photo)
        } catch {
            isGenerating = false
            status = ""
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Не разобрала текст на фото. Попробуй чётче кадр или вставь текст вручную."
        }
    }

    private func saveStubAndOpen(_ stub: Lesson) {
        let id = LessonTopicParser.makeUserLessonId(topic: stub.topicRaw ?? stub.titleRu)
        let hit = TopicCategoryClassifier.classify(stub.topicRaw ?? stub.titleRu)
        let category = UserLessonCatalogStore.shared.ensureCategory(forText: stub.topicRaw ?? stub.titleRu)
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
            topicRaw: stub.topicRaw,
            categoryId: category.id,
            categoryTitleRu: category.titleRu,
            sourceKind: UserLessonSourceKind.topic.rawValue
        )
        do {
            try LessonRepository.shared.saveUser(copy)
            UserLessonCatalogStore.shared.assign(lessonId: copy.id, category: category)
            _ = hit
            onCreated(copy)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Category list

struct UserCategoryLessonsView: View {
    let category: UserLessonCategory
    @State private var repository = LessonRepository.shared

    private var lessons: [Lesson] {
        UserLessonCatalogStore.shared.lessons(in: category.id, from: repository)
    }

    var body: some View {
        List {
            Section {
                Text(category.titleEn)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if lessons.isEmpty {
                Section {
                    Text("Пока пусто — создай урок голосом, текстом или фото.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Уроки · \(lessons.count)") {
                    ForEach(lessons) { lesson in
                        NavigationLink(value: lesson) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(lesson.titleRu).font(.headline)
                                Text(lesson.sceneRu)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                if let kind = lesson.sourceKind {
                                    Text(kind)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(category.titleRu)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { repository.reload() }
    }
}

// MARK: - Camera

private struct CreateLessonCameraPicker: UIViewControllerRepresentable {
    var onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        p.allowsEditing = false
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onFinish(info[.originalImage] as? UIImage)
        }
    }
}
