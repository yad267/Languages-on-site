import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct TranslateView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var pickedItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var photoImage: UIImage?
    @State private var showCamera = false
    @State private var showPhotoSource = false
    @State private var showLibraryPicker = false
    @State private var speaker: SpeechSpeaker?
    @State private var isWorking = false
    @State private var result: TranslationResult?
    @State private var note = ""
    @State private var badge: CoachSourceBadge.Kind = .offline

    // Mic → STT review (no auto-send trash)
    @State private var capture = TimedSpeechCapture()
    @State private var isListening = false
    @State private var awaitingReview = false
    @State private var sttDraft = ""
    @State private var sttHint = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerRow
                inputBlock
                photoPreview
                if isListening || awaitingReview {
                    micReviewCard
                }
                translateButton
                if !note.isEmpty {
                    Text(note)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if let r = result {
                    if let photo = r.photo {
                        photoIdentifyCard(photo, fallback: r)
                    } else {
                        resultBlock(r)
                    }
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture { NavChrome.dismissKeyboard() }
        .navigationTitle("Перевод")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            toolbarItems
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { NavChrome.dismissKeyboard() }
                    .fontWeight(.semibold)
            }
        }
        .confirmationDialog("Фото", isPresented: $showPhotoSource, titleVisibility: .visible) {
            Button("Снять") { showCamera = true }
            Button("Выбрать") { showLibraryPicker = true }
            Button("Отмена", role: .cancel) {}
        }
        .photosPicker(isPresented: $showLibraryPicker, selection: $pickedItem, matching: .images)
        .sheet(isPresented: $showCamera) { cameraSheet }
        .onAppear {
            speaker = SpeechSpeaker(settings: settings)
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-EOSShowPhotoSource") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showPhotoSource = true }
            } else if args.contains("-EOSPickLibrary") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showLibraryPicker = true }
            } else if args.contains("-EOSOpenCamera") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showCamera = true }
            }
            #endif
        }
        .onDisappear {
            capture.cancel()
            speaker?.stop()
        }
        .onChange(of: pickedItem) { _, item in
            Task { await loadPicked(item) }
        }
    }

    private var headerRow: some View {
        HStack {
            Spacer()
            CoachSourceBadge(kind: badge)
        }
    }

    private var inputBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Текст, речь или фото с объекта")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 10) {
                TextEditor(text: $inputText)
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.35))
                    )

                VStack(spacing: 8) {
                    photoButton
                    micButton
                }
            }
        }
    }

    private var photoButton: some View {
        Button { showPhotoSource = true } label: {
            VStack(spacing: 4) {
                Text("📷").font(.system(size: 28))
                Text("Фото").font(.caption.weight(.bold))
            }
            .frame(width: 76)
            .frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.14)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Фото")
    }

    private var micButton: some View {
        Button {
            Task { await toggleMic() }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isListening ? "stop.circle.fill" : "mic.fill")
                    .font(.title2)
                    .foregroundStyle(isListening ? Color.red : Color.accentColor)
                Text(isListening ? "Стоп" : "Сказать")
                    .font(.caption.weight(.bold))
            }
            .frame(width: 76)
            .frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel(isListening ? "Стоп" : "Сказать")
    }

    private var micReviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isListening ? "Слушаю…" : "Распознано")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if isListening {
                Text(capture.partialText.isEmpty ? "…" : capture.partialText)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                HStack {
                    Button("Стоп") { capture.finish() }
                        .buttonStyle(.borderedProminent)
                    Button("Отмена", role: .cancel) {
                        capture.cancel()
                        isListening = false
                        awaitingReview = false
                        sttDraft = ""
                        sttHint = ""
                    }
                }
            } else {
                TextField("Текст…", text: $sttDraft, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                if !sttHint.isEmpty {
                    Text(sttHint).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
                HStack {
                    Button("Перевести") {
                        inputText = sttDraft
                        awaitingReview = false
                        Task { await runTranslate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sttDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Ещё раз") {
                        Task { await toggleMic() }
                    }
                    .buttonStyle(.bordered)

                    Button("Править") { sttHint = "" }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    @ViewBuilder
    private var photoPreview: some View {
        if let photoImage {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: photoImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button(action: clearPhoto) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.65))
                }
                .padding(8)
            }
        }
    }

    private var translateButton: some View {
        Button {
            Task { await runTranslate() }
        } label: {
            Group {
                if isWorking {
                    ProgressView()
                } else {
                    Text(photoData != nil ? "Что на фото?" : "Перевести")
                        .font(.system(size: 20, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isWorking || isListening)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavChrome.backToLessons(dismiss: dismiss)
        }
        ToolbarItem(placement: .topBarTrailing) {
            NavChrome.done(action: { dismiss() }, title: "Готово")
        }
    }

    private var cameraSheet: some View {
        CameraPicker { image in
            if let image {
                photoImage = image
                photoData = image.jpegData(compressionQuality: 0.72)
            }
            showCamera = false
        }
        .ignoresSafeArea()
    }

    // MARK: - Result cards

    @ViewBuilder
    private func photoIdentifyCard(_ p: PhotoIdentifyResult, fallback: TranslationResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if p.unclear {
                Text(p.summaryRU.isEmpty ? "Не разобрал, сними ближе" : p.summaryRU)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.orange)
            } else {
                Text("Что это")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(p.nameEN.isEmpty ? "—" : p.nameEN)
                    .font(.title2.weight(.bold))
                    .textSelection(.enabled)
                Text(p.nameRU.isEmpty ? "—" : p.nameRU)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(p.kind)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    Text(p.confidence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !p.ocrText.isEmpty {
                Divider()
                Text("Текст на фото").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Text(p.ocrText).font(.body.weight(.semibold)).textSelection(.enabled)
                if !p.translationRU.isEmpty {
                    Text(p.translationRU).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !p.translationEN.isEmpty, p.translationEN != p.ocrText {
                    Text(p.translationEN).font(.subheadline).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }

            if p.kind == "document" || !p.documentGuess.isEmpty {
                Divider()
                Text("Документ").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                if !p.documentGuess.isEmpty {
                    Text(p.documentGuess).font(.headline)
                }
                if !p.summaryRU.isEmpty {
                    Text(p.summaryRU).font(.subheadline).foregroundStyle(.secondary)
                }
                if !p.keyFields.isEmpty {
                    ForEach(p.keyFields, id: \.self) { f in
                        Text("· \(f)").font(.footnote)
                    }
                }
            } else if !p.summaryRU.isEmpty, !p.unclear {
                Text(p.summaryRU)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !p.siteTipEN.isEmpty || !p.siteTipRU.isEmpty {
                Divider()
                Text("На объекте").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                if !p.siteTipEN.isEmpty {
                    Text(p.siteTipEN).font(.body.weight(.bold)).textSelection(.enabled)
                }
                if !p.siteTipRU.isEmpty {
                    Text(p.siteTipRU).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Button {
                let en = p.listenEN
                guard !en.isEmpty else { return }
                speaker?.updateSettings(settings)
                speaker?.speakEN(en) { note = speaker?.statusNote ?? "" }
            } label: {
                Label("Слушать EN", systemImage: "speaker.wave.2.fill")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .disabled(p.listenEN.isEmpty)

            Button("В библиотеку") {
                save(fallback)
                note = "Сохранено"
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 48)
            .disabled(p.unclear && p.nameEN.isEmpty)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    @ViewBuilder
    private func resultBlock(_ r: TranslationResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(r.sourceIsRussian ? "RU" : "EN")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
            Text(r.sourceText)
                .font(.title3.weight(.bold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Text(r.sourceIsRussian ? "EN" : "RU")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
            Text(r.translatedText)
                .font(.title2.weight(.bold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !r.tipRu.isEmpty, settings.showTips {
                Text(r.tipRu)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                let en = r.sourceIsRussian ? r.translatedText : r.sourceText
                speaker?.updateSettings(settings)
                speaker?.speakEN(en) { note = speaker?.statusNote ?? "" }
            } label: {
                Label("Слушать EN", systemImage: "speaker.wave.2.fill")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)

            Button("В библиотеку") {
                save(r)
                note = "Сохранено"
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .padding(.top, 8)
    }

    // MARK: - Actions

    private func clearPhoto() {
        photoData = nil
        photoImage = nil
        pickedItem = nil
    }

    private func loadPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let img = UIImage(data: data) {
            await MainActor.run {
                photoImage = img
                photoData = img.jpegData(compressionQuality: 0.72)
            }
        }
    }

    private func toggleMic() async {
        if isListening {
            capture.finish()
            return
        }
        note = ""
        result = nil
        sttDraft = ""
        sttHint = ""
        awaitingReview = false
        isListening = true
        let enLocale = settings.rememberLocale == .enGB ? "en-GB" : "en-IE"
        let locale = TranslationService.translatorMicLocaleId(
            draftOrInput: inputText,
            englishLocale: enLocale
        )
        let text = await capture.captureUntilStopped(localeId: locale, maxSeconds: 45, contextualStrings: [])
        isListening = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if LanguageDetect.classify(trimmed) == .garbage {
            sttDraft = ""
            awaitingReview = false
            note = "Не расслышал — скажи ещё раз"
            return
        }
        sttDraft = trimmed
        awaitingReview = true
        if trimmed.isEmpty {
            sttHint = capture.errorMessage.isEmpty
                ? "Не расслышал (\(locale)) — Ещё раз или Править"
                : capture.errorMessage
        }
    }

    private func runTranslate() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPhoto = photoData != nil
        note = ""
        result = nil

        if text.isEmpty && !hasPhoto {
            note = "Введи текст, скажи или добавь фото"
            return
        }

        // B15: keyboard / STT mash → retry, never Translate.
        if !hasPhoto {
            switch LanguageDetect.classify(text) {
            case .garbage, .empty:
                note = "Не расслышал — скажи ещё раз"
                return
            case .russian, .english:
                break
            }
        }

        isWorking = true
        defer { isWorking = false }

        if hasPhoto, let data = photoData {
            guard data.count > 800 else {
                note = "Не разобрал, сними ближе"
                badge = .offline
                return
            }
            guard settings.geminiEnabledAndReady else {
                note = settings.useGemini ? "Нет ключа Gemini в Настройках" : "Включи Gemini в Настройках"
                badge = .offline
                return
            }
            do {
                let r = try await GeminiSiteCoachService.shared.translatePhoto(
                    imageJPEG: data,
                    caption: text,
                    settings: settings
                )
                if let err = r.geminiErrorRU, r.photo?.unclear == true || (r.sourceText.isEmpty && r.translatedText.isEmpty && r.photo == nil) {
                    note = err
                    result = r.photo != nil ? r : nil
                    badge = .gemini
                    return
                }
                if r.sourceText.isEmpty && r.translatedText.isEmpty && r.photo == nil {
                    note = "Не разобрал, сними ближе"
                    badge = .offline
                    return
                }
                result = r
                badge = .gemini
                note = text.isEmpty ? "" : "Текст + фото"
            } catch let e as GeminiRequestError {
                note = e.shortRU
                badge = .offline
            } catch {
                note = "Нет сети / таймаут Gemini"
                badge = .offline
            }
            return
        }

        let offline = TranslationService.translateOffline(recognized: text)
        if offline.matched {
            result = offline
            badge = .offline
            return
        }
        note = settings.geminiEnabledAndReady
            ? "Офлайн не нашёл — спрашиваю Gemini…"
            : (settings.useGemini ? "Нет ключа Gemini" : "Gemini выключен")
        let cloud = await TranslationService.translate(recognized: text, settings: settings)
        let empty = cloud.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && cloud.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty {
            note = cloud.geminiErrorRU ?? "Пустой перевод — попробуй другую фразу"
            badge = .offline
            return
        }
        result = cloud
        badge = cloud.viaGemini ? .gemini : .offline
        note = cloud.viaGemini ? "" : (cloud.geminiErrorRU ?? note)
    }

    private func save(_ r: TranslationResult) {
        let en: String
        let ru: String
        if let p = r.photo, !p.nameEN.isEmpty {
            en = p.nameEN
            ru = p.nameRU.isEmpty ? r.translatedText : p.nameRU
        } else {
            en = r.sourceIsRussian ? r.translatedText : r.sourceText
            ru = r.sourceIsRussian ? r.sourceText : r.translatedText
        }
        let item = LibraryItem(
            source: .manual,
            en: en,
            ru: ru,
            tipRu: r.tipRu,
            tag: r.tag
        )
        modelContext.insert(item)
        try? modelContext.save()
    }
}

// MARK: - Camera

private struct CameraPicker: UIViewControllerRepresentable {
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
