import SwiftUI

/// B4 Формы глагола — GrammarPatterns + выбор глагола.
struct TutorVerbFormsView: View {
    var contentMode: TutorContentMode = .site

    @State private var lemma = "need"
    @State private var tense: GrammarTense = .present
    @State private var mode: Mode = .gap
    @State private var topic = "Safe Pass"
    @State private var item: GrammarAssignment?
    @State private var answer = ""
    @State private var feedback: String?
    @State private var revealed = false
    @State private var whySeed: String?

    private enum Mode: String, CaseIterable, Identifiable {
        case gap, toQuestion, toNegative, tenseShift
        var id: String { rawValue }
        var title: String {
            switch self {
            case .gap: return "Fill gap"
            case .toQuestion: return "→ Question"
            case .toNegative: return "→ Negative"
            case .tenseShift: return "Смена tense"
            }
        }
    }

    private var lemmas: [String] {
        contentMode == .site
            ? ["need", "put", "sign", "check", "wear", "turn", "have", "be", "cut", "drill"]
            : ["take", "get", "make", "go", "come", "give", "want", "have", "be", "do"]
    }

    private var topics: [String] {
        contentMode == .site
            ? ["Safe Pass", "PPE", "Tools", "CCTV"]
            : ["Home", "Food", "Travel", "Phone"]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Глагол", selection: $lemma) {
                    ForEach(lemmas, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)

                Picker("Tense", selection: $tense) {
                    ForEach(GrammarTense.allCases) { Text($0.titleRU).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: tense) { _, _ in generate() }

                Picker("Режим", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .onChange(of: mode) { _, _ in generate() }

                Picker("Тема", selection: $topic) {
                    ForEach(topics, id: \.self) { Text($0) }
                }
                .onChange(of: topic) { _, _ in generate() }
                .onChange(of: lemma) { _, _ in generate() }

                Button("Сгенерировать") { generate() }
                    .buttonStyle(.borderedProminent)

                if let item {
                    Text(item.promptEN)
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.promptRU)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField("Ответ", text: $answer)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if let feedback {
                        Text(feedback).font(.headline)
                            .foregroundStyle((item.matches(answer) && revealed) ? .green : .orange)
                    }
                    if revealed {
                        Text("Ожидаем: \(item.expected.first ?? "—")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Проверить") { check() }
                            .buttonStyle(.borderedProminent)
                        if revealed {
                            Button("Ещё раз") { generate() }
                            Button("Почему?") { whySeed = "почему: \(item.expected.first ?? "")" }
                        }
                    }
                }
            }
            .padding(16)
            .onTapGesture { NavChrome.dismissKeyboard() }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Формы глагола")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $whySeed) { TutorWhyView(initialQuestion: $0) }
        .onAppear {
            TutorBankStore.setMode(contentMode)
            if !lemmas.contains(lemma) { lemma = lemmas[0] }
            if !topics.contains(topic) { topic = topics[0] }
            generate()
        }
    }

    private func generate() {
        TutorBankStore.setMode(contentMode)
        guard let verb = TutorBankStore.verb(named: lemma) else {
            feedback = "Нет глагола \(lemma) в банке"
            item = nil
            return
        }
        switch mode {
        case .gap:
            item = GrammarPatterns.fillGap(verb: verb, tense: tense, siteTopic: topic, subject: .they)
        case .toQuestion:
            item = GrammarPatterns.transform(
                verb: verb, from: .statement, to: .question, tense: tense, siteTopic: topic, subject: .they
            )
        case .toNegative:
            item = GrammarPatterns.transform(
                verb: verb, from: .statement, to: .negative, tense: tense, siteTopic: topic, subject: .they
            )
        case .tenseShift:
            // Picker tense = TARGET (Present/Past/Future). Source = another tense.
            let target = tense
            let source: GrammarTense = {
                switch target {
                case .present: return .past
                case .past: return .present
                case .future: return .present
                }
            }()
            let src = GrammarPatterns.buildLine(
                verb: verb, tense: source, speechAct: .statement, subject: .they, noun: "gate"
            )
            let dst = GrammarPatterns.buildLine(
                verb: verb, tense: target, speechAct: .statement, subject: .they, noun: "gate"
            )
            item = GrammarAssignment(
                kind: "tense",
                promptEN: "→ \(target.titleRU): \(src)",
                promptRU: "Смени время на \(target.titleRU).",
                expected: [dst],
                siteTopic: topic,
                verbLemma: verb.lemma,
                tense: target,
                speechAct: .statement
            )
        }
        answer = ""
        feedback = nil
        revealed = false
    }

    private func check() {
        NavChrome.dismissKeyboard()
        guard let item else { return }
        revealed = true
        feedback = item.matches(answer) ? "Ок" : "Сверь с ответом"
    }
}
