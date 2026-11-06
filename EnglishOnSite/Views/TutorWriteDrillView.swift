import SwiftUI

/// B2 Писать: gap / transform · проверка expected · next item.
struct TutorWriteDrillView: View {
    var contentMode: TutorContentMode = .site

    @Environment(\.dismiss) private var dismiss

    @State private var items: [GrammarAssignment] = []
    @State private var index = 0
    @State private var answer = ""
    @State private var feedback: String?
    @State private var revealed = false
    @State private var whySeed: String?
    @State private var topic = "Safe Pass"
    @State private var finished = false
    @State private var advanceTask: Task<Void, Never>?

    private var topics: [String] {
        contentMode == .site
            ? ["Safe Pass", "PPE", "Containment", "Tools", "CCTV"]
            : ["Home", "Food", "Travel", "Shopping", "Phone"]
    }

    private var current: GrammarAssignment? {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if finished {
                    finishedBlock
                } else {
                    Picker("Тема", selection: $topic) {
                        ForEach(topics, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: topic) { _, _ in rebuild() }

                    Text("\(min(index + 1, max(items.count, 1))) / \(max(items.count, 1))")
                        .font(.headline)

                    if items.isEmpty {
                        Text("Нет заданий — открой «Глаголы» и добавь lemma, или проверь банк verbs.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                        Button("Обновить") { rebuild() }
                            .buttonStyle(.borderedProminent)
                    } else if let c = current {
                        Text(c.promptEN)
                            .font(.title3.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(c.promptRU)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField("Ответ EN", text: $answer)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { NavChrome.dismissKeyboard(); check() }

                        if let feedback {
                            Text(feedback)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(revealed && !(current?.matches(answer) ?? false) ? .orange : .green)
                        }

                        if revealed, let c = current {
                            Text("Ответ: \(c.expected.first ?? "—")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button("Проверить") { check() }
                                .buttonStyle(.borderedProminent)
                            if revealed {
                                Button(index + 1 >= items.count ? "Готово" : "Дальше") { next() }
                                    .buttonStyle(.bordered)
                                Button("Почему?") {
                                    whySeed = "почему: \(c.expected.first ?? c.promptEN)"
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .contentShape(Rectangle())
            .onTapGesture { NavChrome.dismissKeyboard() }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Писать")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { NavChrome.dismissKeyboard() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Новый") { rebuild() }
            }
        }
        .navigationDestination(item: $whySeed) { seed in
            TutorWhyView(initialQuestion: seed)
        }
        .onAppear {
            TutorBankStore.setMode(contentMode)
            if !topics.contains(topic) { topic = topics[0] }
            rebuild()
        }
        .onDisappear { advanceTask?.cancel() }
    }

    private var finishedBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 24)
            Text("Набор готов").font(.title2.weight(.bold))
            Text("\(items.count) заданий · можно новый набор или назад.")
                .foregroundStyle(.secondary)
            Button("Ещё набор") { rebuild() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 48)
            Button("К упражнениям") { dismiss() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 48)
            Spacer()
        }
    }

    private func rebuild() {
        advanceTask?.cancel()
        TutorBankStore.setMode(contentMode)
        finished = false
        let lemmas = contentMode == .site
            ? ["need", "put", "sign", "check", "wear", "turn", "cut"]
            : ["take", "get", "make", "go", "come", "give", "want"]
        let verbs = lemmas.compactMap { TutorBankStore.verb(named: $0) }
        items = GrammarPatterns.worksheet(
            verbs: verbs,
            siteTopic: topic,
            count: 8,
            includePhrasal: true,
            includeOpposite: false
        )
        index = 0
        answer = ""
        feedback = nil
        revealed = false
    }

    private func check() {
        NavChrome.dismissKeyboard()
        guard let c = current, !finished else { return }
        // Already revealed + correct → treat as Next (B1).
        if revealed, c.matches(answer) {
            next()
            return
        }
        revealed = true
        if c.matches(answer) {
            feedback = "Ок"
            CommandFeedback.acknowledged()
            advanceTask?.cancel()
            advanceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                next()
            }
        } else {
            feedback = "Почти — смотри ответ"
        }
    }

    private func next() {
        advanceTask?.cancel()
        guard !items.isEmpty else { return }
        if index + 1 >= items.count {
            finished = true
            feedback = nil
            revealed = false
            answer = ""
            return
        }
        index += 1
        answer = ""
        feedback = nil
        revealed = false
    }
}
