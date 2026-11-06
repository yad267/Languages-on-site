import SwiftUI
import PhotosUI
import UIKit

/// C) Лист на печать: генерация → PDF Share/Print → фото → Gemini проверка.
struct TutorPrintSheetView: View {
    @Environment(AppSettings.self) private var settings
    var contentMode: TutorContentMode = .site

    @State private var topic = "Safe Pass"
    @State private var selectedLemmas: Set<String> = ["need", "put", "sign"]
    @State private var count = 10
    @State private var includePhrasal = true
    @State private var includeOpposite = true
    @State private var assignments: [GrammarAssignment] = []
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var picked: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var photoImage: UIImage?
    @State private var checkNote = ""
    @State private var checkResult = ""
    @State private var isChecking = false
    @State private var showNoKey = false

    private var lemmaChoices: [String] {
        contentMode == .site
            ? ["need", "put", "sign", "check", "wear", "turn", "have", "be", "cut", "drill"]
            : ["take", "get", "make", "go", "come", "give", "want", "have", "be", "do"]
    }

    private var topicChoices: [String] {
        contentMode == .site
            ? ["Safe Pass", "PPE", "Containment", "Tools", "CCTV", "Induction"]
            : ["Home", "Food", "Travel", "Shopping", "Phone", "Friends"]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Тема")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(topicChoices, id: \.self) { t in
                            Button(t) { topic = t }
                                .buttonStyle(.bordered)
                                .tint(topic == t ? .accentColor : .secondary)
                        }
                    }
                }

                Text("Глаголы")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                FlowLemmas(selected: $selectedLemmas, choices: lemmaChoices)

                Picker("Заданий", selection: $count) {
                    Text("8").tag(8)
                    Text("10").tag(10)
                    Text("12").tag(12)
                }
                .pickerStyle(.segmented)

                Toggle("1 phrasal", isOn: $includePhrasal)
                Toggle("1 opposite", isOn: $includeOpposite)

                Button("Сгенерировать лист") { generate() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 48)

                if !assignments.isEmpty {
                    previewCard
                    Button("Share / Print PDF") { makePDF() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, minHeight: 44)

                    Text("Я написал")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    PhotosPicker(selection: $picked, matching: .images) {
                        Label("Фото листа", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)

                    if let photoImage {
                        Image(uiImage: photoImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Button {
                        Task { await checkPhoto() }
                    } label: {
                        if isChecking {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 48)
                        } else {
                            Text("Проверить").frame(maxWidth: .infinity, minHeight: 48)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(photoData == nil || isChecking)

                    if !checkNote.isEmpty {
                        Text(checkNote).font(.caption).foregroundStyle(.orange)
                    }
                    if !checkResult.isEmpty {
                        Text(checkResult)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(16)
            .onTapGesture { NavChrome.dismissKeyboard() }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Лист на печать")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .alert("Нужен Gemini", isPresented: $showNoKey) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Для проверки фото нужен ключ Gemini в Настройках.")
        }
        .onChange(of: picked) { _, item in
            Task { await loadPhoto(item) }
        }
        .onAppear {
            TutorBankStore.setMode(contentMode)
            if !topicChoices.contains(topic) {
                topic = topicChoices[0]
            }
            let allowed = Set(lemmaChoices)
            selectedLemmas = selectedLemmas.intersection(allowed)
            if selectedLemmas.isEmpty {
                selectedLemmas = Set(lemmaChoices.prefix(3))
            }
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Languages on site · \(topic)")
                .font(.headline)
            Text(Date.now.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(assignments.enumerated()), id: \.element.id) { i, a in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(i + 1). \(a.promptEN)")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(a.promptRU)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.tertiary)
                        .frame(height: 28)
                }
            }
            Text("Languages on site · \(topic) · \(Date.now.formatted(date: .numeric, time: .omitted))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func generate() {
        TutorBankStore.ensureLoaded()
        let verbs = selectedLemmas.compactMap { TutorBankStore.verb(named: $0) }
        assignments = GrammarPatterns.worksheet(
            verbs: verbs,
            siteTopic: topic,
            count: count,
            includePhrasal: includePhrasal,
            includeOpposite: includeOpposite
        )
        checkResult = ""
        checkNote = ""
        photoData = nil
        photoImage = nil
    }

    private func makePDF() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EOS-\(topic.replacingOccurrences(of: " ", with: "-")).pdf")
        let page = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 @ 72dpi
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        do {
            try renderer.writePDF(to: url) { ctx in
                ctx.beginPage()
                let title = "Languages on site · \(topic)" as NSString
                title.draw(at: CGPoint(x: 40, y: 36), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 16),
                ])
                let date = Date.now.formatted(date: .abbreviated, time: .omitted) as NSString
                date.draw(at: CGPoint(x: 40, y: 58), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 11),
                    .foregroundColor: UIColor.secondaryLabel,
                ])
                var y: CGFloat = 90
                for (i, a) in assignments.enumerated() {
                    let block = "\(i + 1). \(a.promptEN)\n\(a.promptRU)" as NSString
                    let rect = CGRect(x: 40, y: y, width: 515, height: 60)
                    block.draw(in: rect, withAttributes: [
                        .font: UIFont.systemFont(ofSize: 12),
                    ])
                    y += 70
                    let line = UIBezierPath()
                    line.move(to: CGPoint(x: 40, y: y))
                    line.addLine(to: CGPoint(x: 555, y: y))
                    UIColor.lightGray.setStroke()
                    line.lineWidth = 1
                    line.stroke()
                    y += 24
                    if y > 780 {
                        ctx.beginPage()
                        y = 40
                    }
                }
                let foot = "Languages on site · \(topic) · \(Date.now.formatted(date: .numeric, time: .omitted))" as NSString
                foot.draw(at: CGPoint(x: 40, y: 810), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 9),
                    .foregroundColor: UIColor.tertiaryLabel,
                ])
            }
            shareURL = url
            showShare = true
        } catch {
            checkNote = "PDF ошибка"
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let img = UIImage(data: data) {
            await MainActor.run {
                photoImage = img
                photoData = img.jpegData(compressionQuality: 0.72)
            }
        }
    }

    private func checkPhoto() async {
        guard let data = photoData, data.count > 800 else {
            checkNote = "Добавь фото листа"
            return
        }
        guard settings.geminiEnabledAndReady else {
            showNoKey = true
            return
        }
        isChecking = true
        checkNote = ""
        defer { isChecking = false }
        let key = assignments.enumerated().map { "\($0.offset + 1). \($0.element.expected.first ?? "")" }.joined(separator: "\n")
        do {
            let text = try await GeminiSiteCoachService.shared.checkWorksheetPhoto(
                imageJPEG: data,
                topic: topic,
                answerKey: key
            )
            checkResult = text
        } catch let e as GeminiRequestError {
            checkNote = e.shortRU
        } catch {
            checkNote = "Нет сети / таймаут"
        }
    }
}

private struct FlowLemmas: View {
    @Binding var selected: Set<String>
    let choices: [String]

    var body: some View {
        FlexibleWrap(choices) { lemma in
            Button(lemma) {
                if selected.contains(lemma) { selected.remove(lemma) }
                else { selected.insert(lemma) }
            }
            .buttonStyle(.bordered)
            .tint(selected.contains(lemma) ? .accentColor : .secondary)
            .font(.caption.weight(.semibold))
        }
    }
}

/// Simple wrap layout without external deps.
private struct FlexibleWrap<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let content: (Data.Element) -> Content

    init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    var body: some View {
        // Use LazyVGrid as pragmatic wrap
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(Array(data), id: \.self) { content($0) }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
