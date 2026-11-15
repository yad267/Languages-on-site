import SwiftUI

/// Guided phrasal sentence lesson: gap fill + hints (RU / first letter / multiple choice).
struct TutorPhrasalSentenceView: View {
    var contentMode: TutorContentMode = .site

    @Environment(AppSettings.self) private var settings

    @State private var deck: [PhrasalEntry] = []
    @State private var index = 0
    @State private var answer = ""
    @State private var choices: [String] = []
    @State private var feedback: String?
    @State private var passed = false
    @State private var finished = false
    @State private var showRuHint = false
    @State private var showLetterHint = false
    @State private var showChoices = false
    @State private var speaker: SpeechSpeaker?

    private var current: PhrasalEntry? {
        guard deck.indices.contains(index) else { return nil }
        return deck[index]
    }

    private var targetSentence: String {
        guard let p = current else { return "" }
        let ex = p.exampleEn.trimmingCharacters(in: .whitespacesAndNewlines)
        return ex.isEmpty ? "Please use \(p.en) carefully." : ex
    }

    private var targetRu: String {
        guard let p = current else { return "" }
        let ru = p.exampleRu.trimmingCharacters(in: .whitespacesAndNewlines)
        return ru.isEmpty ? p.ru : ru
    }

    /// Example with the phrasal blanked (one blank).
    private var gapSentence: String {
        guard let p = current else { return "" }
        let ex = targetSentence
        if let regex = try? NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: p.en),
            options: [.caseInsensitive]
        ) {
            let full = NSRange(ex.startIndex..<ex.endIndex, in: ex)
            if let match = regex.firstMatch(in: ex, options: [], range: full),
               let r = Range(match.range, in: ex) {
                return ex.replacingCharacters(in: r, with: "______")
            }
        }
        return "______ — \(ex)"
    }

    private var firstLetterHint: String {
        guard let p = current else { return "" }
        let parts = p.en.split(separator: " ").map(String.init)
        return parts.map { w -> String in
            guard let ch = w.first else { return "?" }
            let rest = String(repeating: "·", count: max(0, w.count - 1))
            return "\(ch)\(rest)"
        }.joined(separator: " ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if finished {
                    finishedBlock
                } else if deck.isEmpty {
                    Text("Нет phrasal с примером в банке")
                        .foregroundStyle(.secondary)
                    Button("Обновить") { rebuild() }
                        .buttonStyle(.borderedProminent)
                } else if let p = current {
                    lessonChrome(p)
                    gapCard
                    hintsBlock
                    answerBlock(p)
                    actionRow
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { NavChrome.dismissKeyboard() }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaPadding(.bottom, 12)
        .navigationTitle("Phrasal · предложение")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { NavChrome.dismissKeyboard() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Новый урок") { rebuild() }
            }
        }
        .onAppear {
            TutorBankStore.setMode(contentMode)
            if speaker == nil { speaker = SpeechSpeaker(settings: settings) }
            if deck.isEmpty { rebuild() }
        }
    }

    private var finishedBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Урок готов")
                .font(.title2.weight(.bold))
            Text("\(deck.count) phrasal · предложения с подсказками")
                .foregroundStyle(.secondary)
            Button("Ещё урок") { rebuild() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func lessonChrome(_ p: PhrasalEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(index + (passed ? 1 : 0)), total: Double(max(deck.count, 1)))
                .tint(.accentColor)
            Text("Шаг \(index + 1) из \(deck.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(p.en)
                .font(.system(size: 28, weight: .bold))
            Text(p.ru)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("Вставь этот phrasal в предложение")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }

    private var gapCard: some View {
        Text(gapSentence)
            .font(.title3.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
    }

    private var hintsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Подсказки")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                Button {
                    showRuHint = true
                } label: {
                    Label("RU", systemImage: "character.bubble")
                }
                .buttonStyle(.bordered)
                .disabled(showRuHint)

                Button {
                    showLetterHint = true
                } label: {
                    Label("Буква", systemImage: "textformat")
                }
                .buttonStyle(.bordered)
                .disabled(showLetterHint)

                Button {
                    showChoices = true
                    if choices.isEmpty { choices = makeChoices() }
                } label: {
                    Label("Варианты", systemImage: "list.bullet")
                }
                .buttonStyle(.bordered)
                .disabled(showChoices)
            }

            if showRuHint {
                Text(targetRu)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.08))
                    )
            }

            if showLetterHint {
                Text("Начинается так: \(firstLetterHint)")
                    .font(.subheadline.weight(.semibold))
                    .monospaced()
            }

            if showChoices {
                VStack(spacing: 8) {
                    ForEach(choices, id: \.self) { option in
                        Button {
                            answer = option
                            check(selected: option)
                        } label: {
                            Text(option)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(.bordered)
                        .disabled(passed)
                    }
                }
            }
        }
    }

    private func answerBlock(_ p: PhrasalEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ответ — только phrasal (как в банке)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("например: \(p.en)", text: $answer)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(passed)
                .submitLabel(.done)
                .onSubmit { NavChrome.dismissKeyboard(); check() }

            if let feedback {
                Text(feedback)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(passed ? .green : .orange)
            }

            if passed {
                Text("Полное: \(targetSentence)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionRow: some View {
        HStack {
            Button("Проверить") { check() }
                .buttonStyle(.borderedProminent)
                .disabled(passed || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("▶") {
                speaker?.updateSettings(settings)
                speaker?.speakEN(targetSentence)
            }
            .buttonStyle(.bordered)

            if passed {
                Button(index + 1 >= deck.count ? "Финиш" : "Дальше") { next() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Lesson flow

    private func rebuild() {
        TutorBankStore.ensureLoaded()
        let pool = TutorBankStore.phrasals.filter {
            !$0.exampleEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        deck = Array(pool.shuffled().prefix(8))
        index = 0
        finished = deck.isEmpty
        resetStep()
    }

    private func resetStep() {
        answer = ""
        feedback = nil
        passed = false
        showRuHint = false
        showLetterHint = false
        showChoices = false
        choices = makeChoices()
    }

    private func next() {
        if index + 1 >= deck.count {
            finished = true
        } else {
            index += 1
            resetStep()
        }
    }

    private func check(selected: String? = nil) {
        guard let p = current, !passed else { return }
        NavChrome.dismissKeyboard()
        let raw = (selected ?? answer).trimmingCharacters(in: .whitespacesAndNewlines)
        answer = raw
        if PhraseSimilarity.compactKey(raw) == PhraseSimilarity.compactKey(p.en)
            || PhraseSimilarity.passes(recognized: raw, expected: p.en) {
            passed = true
            feedback = "Верно"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            passed = false
            feedback = "Не то — возьми подсказку или варианты"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func makeChoices() -> [String] {
        guard let p = current else { return [] }
        var opts = Set<String>([p.en])
        let bank = TutorBankStore.phrasals.map(\.en).filter { $0.lowercased() != p.en.lowercased() }
        for decoy in bank.shuffled() {
            opts.insert(decoy)
            if opts.count >= 4 { break }
        }
        return opts.shuffled()
    }
}
