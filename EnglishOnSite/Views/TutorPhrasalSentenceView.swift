import SwiftUI

/// Phrasal → sentence: see the verb, complete / build the example sentence.
struct TutorPhrasalSentenceView: View {
    var contentMode: TutorContentMode = .site

    @State private var deck: [PhrasalEntry] = []
    @State private var index = 0
    @State private var answer = ""
    @State private var feedback: String?
    @State private var revealed = false
    @State private var finished = false
    @State private var speaker: SpeechSpeaker?
    @Environment(AppSettings.self) private var settings

    private var current: PhrasalEntry? {
        guard deck.indices.contains(index) else { return nil }
        return deck[index]
    }

    /// Gap prompt: example with phrasal blanked out when possible.
    private var gapPrompt: String {
        guard let p = current else { return "" }
        let ex = p.exampleEn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ex.isEmpty else {
            return "Write one short sentence with «\(p.en)»."
        }
        if let regex = try? NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: p.en),
            options: [.caseInsensitive]
        ) {
            let full = NSRange(ex.startIndex..<ex.endIndex, in: ex)
            if let match = regex.firstMatch(in: ex, options: [], range: full),
               let r = Range(match.range, in: ex) {
                return ex.replacingCharacters(in: r, with: "_____")
            }
        }
        return "Write one short sentence with «\(p.en)»."
    }

    private var expectedSentence: String {
        guard let p = current else { return "" }
        let ex = p.exampleEn.trimmingCharacters(in: .whitespacesAndNewlines)
        return ex.isEmpty ? "I can use \(p.en) on site." : ex
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if finished {
                    Text("Готово")
                        .font(.title2.weight(.bold))
                    Text("\(deck.count) предложений с phrasal")
                        .foregroundStyle(.secondary)
                    Button("Ещё раз") { rebuild() }
                        .buttonStyle(.borderedProminent)
                } else if deck.isEmpty {
                    Text("Нет phrasal в банке")
                        .foregroundStyle(.secondary)
                    Button("Обновить") { rebuild() }
                        .buttonStyle(.borderedProminent)
                } else if let p = current {
                    Text("\(index + 1) / \(deck.count)")
                        .font(.headline)

                    Text(p.en)
                        .font(.system(size: 28, weight: .bold))
                    Text(p.ru)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("Вставь phrasal / допиши предложение")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Text(gapPrompt)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    if !p.exampleRu.isEmpty {
                        Text(p.exampleRu)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }

                    TextField("EN предложение или phrasal", text: $answer)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { NavChrome.dismissKeyboard(); check() }

                    if let feedback {
                        Text(feedback)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(revealed && !passes(answer, for: p) ? .orange : .green)
                    }

                    if revealed {
                        Text("Образец: \(expectedSentence)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Проверить") { check() }
                            .buttonStyle(.borderedProminent)
                        Button("▶") {
                            speaker?.updateSettings(settings)
                            speaker?.speakEN(expectedSentence)
                        }
                        .buttonStyle(.bordered)
                        if revealed {
                            Button(index + 1 >= deck.count ? "Готово" : "Дальше") { next() }
                                .buttonStyle(.bordered)
                        }
                    }
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
                Button("Новый") { rebuild() }
            }
        }
        .onAppear {
            TutorBankStore.setMode(contentMode)
            if speaker == nil { speaker = SpeechSpeaker(settings: settings) }
            if deck.isEmpty { rebuild() }
        }
    }

    private func rebuild() {
        TutorBankStore.ensureLoaded()
        let knownFiltered = PairsKnownStore.filterPhrasals(TutorBankStore.phrasals)
        // Prefer items that have an example sentence.
        let withEx = knownFiltered.filter {
            !$0.exampleEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let pool = withEx.isEmpty ? knownFiltered : withEx
        deck = Array(pool.shuffled().prefix(10))
        index = 0
        answer = ""
        feedback = nil
        revealed = false
        finished = deck.isEmpty
    }

    private func check() {
        guard let p = current else { return }
        NavChrome.dismissKeyboard()
        revealed = true
        if passes(answer, for: p) {
            feedback = "Ок"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { next() }
        } else {
            feedback = "Ещё раз — нужен «\(p.en)» в предложении"
        }
    }

    private func next() {
        answer = ""
        feedback = nil
        revealed = false
        if index + 1 >= deck.count {
            finished = true
        } else {
            index += 1
        }
    }

    private func passes(_ raw: String, for p: PhrasalEntry) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let compact = PhraseSimilarity.compactKey(trimmed)
        let phrasal = PhraseSimilarity.compactKey(p.en)
        // Typed just the phrasal, or full sentence containing it.
        if compact == phrasal { return true }
        if PhraseSimilarity.passes(recognized: trimmed, expected: expectedSentence) { return true }
        let norm = PhraseSimilarity.normalize(trimmed)
        let needle = PhraseSimilarity.normalize(p.en)
        return norm.contains(needle) && norm.split(separator: " ").count >= max(2, needle.split(separator: " ").count)
    }
}
