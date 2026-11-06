import SwiftUI

private struct WhyHistoryItem: Identifiable, Codable, Hashable {
    var id: String { q }
    let q: String
    let a: String
}

/// Режим «Почему так?»: 1 правило RU + 2 EN примера с объекта.
struct TutorWhyView: View {
    @Environment(AppSettings.self) private var settings

    let initialQuestion: String?

    @State private var draft = ""
    @State private var answer: TutorWhyAnswer?
    @State private var history: [WhyHistoryItem] = WhyHistoryStore.load()
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var showNoKeyAlert = false
    @State private var didAutoAsk = false

    private let chips = [
        "почему put up не put on?",
        "зачем article the?",
        "почему Present Simple на объекте?",
        "hand in или hand over?",
        "turn off vs switch off?",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Спроси коротко — получи 1 правило и 2 примера с Ireland site.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Почему…?", text: $draft, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isBusy)
                    .submitLabel(.done)
                    .onSubmit { NavChrome.dismissKeyboard() }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.self) { chip in
                            Button(chip) {
                                draft = chip
                                Task { await ask() }
                            }
                            .buttonStyle(.bordered)
                            .font(.caption.weight(.semibold))
                            .disabled(isBusy)
                        }
                    }
                }

                Button {
                    Task { await ask() }
                } label: {
                    if isBusy {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 48)
                    } else {
                        Text("Объясни").frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }

                if let answer {
                    answerCard(answer)
                }

                if !history.isEmpty {
                    Text("Недавние")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(history) { item in
                        Button {
                            draft = item.q
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.q).font(.subheadline.weight(.semibold))
                                Text(item.a).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { NavChrome.dismissKeyboard() }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Почему так?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { NavChrome.dismissKeyboard() }
                    .fontWeight(.semibold)
            }
        }
        .alert("Нужен Gemini", isPresented: $showNoKeyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Вставь ключ Gemini в Настройках.")
        }
        .onAppear {
            guard !didAutoAsk else { return }
            if let q = initialQuestion?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
                didAutoAsk = true
                draft = q
                Task { await ask() }
            }
        }
    }

    private func answerCard(_ a: TutorWhyAnswer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("Правило", a.ruleRU)
            if !a.example1EN.isEmpty {
                labeled("Пример 1", "\(a.example1EN)\n\(a.example1RU)")
            }
            if !a.example2EN.isEmpty {
                labeled("Пример 2", "\(a.example2EN)\n\(a.example2RU)")
            }
            if !a.siteLineRU.isEmpty {
                labeled("На сайте", a.siteLineRU)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ask() async {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard settings.geminiEnabledAndReady else {
            showNoKeyAlert = true
            errorMessage = "Нет ключа Gemini"
            return
        }
        NavChrome.dismissKeyboard()
        errorMessage = nil
        isBusy = true
        do {
            let a = try await GeminiSiteCoachService.shared.tutorWhy(question: q)
            answer = a
            var next = history.filter { $0.q != q }
            next.insert(WhyHistoryItem(q: q, a: a.ruleRU), at: 0)
            history = Array(next.prefix(8))
            WhyHistoryStore.save(history)
        } catch let e as GeminiRequestError {
            errorMessage = e.shortRU
        } catch {
            errorMessage = "Нет сети / таймаут"
        }
        isBusy = false
    }
}

private enum WhyHistoryStore {
    private static let key = "tutorWhyHistory_v1"

    static func load() -> [WhyHistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([WhyHistoryItem].self, from: data) else { return [] }
        return arr
    }

    static func save(_ items: [WhyHistoryItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
