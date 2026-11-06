import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportRoleplayView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var onSaved: (RoleplayScript) -> Void

    @State private var rawText = ""
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var isParsing = false
    @State private var showImporter = false
    @State private var preview: RoleplayScript?
    @State private var parseTask: Task<Void, Never>?
    @State private var showSinglePhrase = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $rawText)
                        .frame(minHeight: 160)
                        .disabled(isParsing)
                        .font(.body)

                    HStack {
                        Button {
                            showImporter = true
                        } label: {
                            Label("Файл .txt / .docx", systemImage: "doc.badge.plus")
                        }
                        .disabled(isParsing)

                        Spacer()

                        if isParsing {
                            ProgressView()
                            Button("Отмена", role: .cancel) {
                                parseTask?.cancel()
                                parseTask = nil
                                isParsing = false
                                status = ""
                            }
                        } else {
                            Button("Разобрать") { startParse() }
                                .buttonStyle(.borderedProminent)
                                .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                        }
                    }

                    Button("Одна фраза → Мои фразы") {
                        showSinglePhrase = true
                    }
                    .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                } header: {
                    Text("Вставь диалог Name: или файл")
                } footer: {
                    Text(status.isEmpty
                         ? "Формат Name: line… Свободный запрос («tray basket») — на экране Roleplay → «Сделать диалог»."
                         : status)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                        Button("Сохранить как одну фразу") {
                            showSinglePhrase = true
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let preview {
                    Section("Превью · \(preview.lines.count) реплик") {
                        Text(preview.titleRu)
                            .font(.headline)
                        Text(preview.sceneRu)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ForEach(preview.roles) { role in
                            Text("\(role.slot.uppercased()): \(role.name)")
                                .font(.caption.weight(.semibold))
                        }
                        ForEach(preview.lines.prefix(6)) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.role)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                Text(line.en)
                                Text(line.ru)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        if preview.lines.count > 6 {
                            Text("… ещё \(preview.lines.count - 6)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Сохранить и тренировать") {
                            save(preview)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Импорт диалога")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NavChrome.close(dismiss: dismiss)
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.plainText, .text, UTType(filenameExtension: "docx") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .sheet(isPresented: $showSinglePhrase) {
                AddMyPhraseView(
                    initialText: rawText,
                    source: .importText,
                    onSaved: { _ in dismiss() }
                )
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func startParse() {
        errorMessage = nil
        preview = nil
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // B17: short single phrase → Мои фразы, not «Не нашёл реплики».
        if trimmed.count < 20, !trimmed.contains(":"), LanguageDetect.classify(trimmed) != .garbage {
            showSinglePhrase = true
            return
        }
        isParsing = true
        status = settings.geminiEnabledAndReady ? "Gemini разбирает…" : "Локальный парсер…"
        parseTask = Task {
            do {
                let script = try await RoleplayParserService.parse(rawText: rawText, settings: settings)
                guard !Task.isCancelled else { return }
                preview = script
                status = "Готово · \(script.lines.count) реплик"
            } catch {
                guard !Task.isCancelled else { return }
                // Offer single-phrase path instead of dead end.
                errorMessage = (error.localizedDescription) + " — или сохрани как одну фразу."
                status = ""
            }
            isParsing = false
            parseTask = nil
        }
    }

    private func save(_ script: RoleplayScript) {
        do {
            try RoleplayRepository.shared.save(script)
            // B17b: dialogue lines also land in one Мои фразы base.
            for line in script.lines {
                _ = LibraryStore.add(
                    context: modelContext,
                    source: .roleplay,
                    en: line.en,
                    ru: line.ru,
                    tipRu: line.tipRu ?? script.titleRu,
                    tag: .tools,
                    transcriptRaw: script.sourceRaw,
                    itemType: .sentence
                )
            }
            onSaved(script)
            dismiss()
        } catch {
            errorMessage = "Не сохранил: \(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e):
            errorMessage = e.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                rawText = try DocumentTextExtractor.extract(from: url)
                status = "Файл загружен · \(url.lastPathComponent)"
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
