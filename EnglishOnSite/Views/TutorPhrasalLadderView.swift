import SwiftUI

/// Репетитор: phrasal ladder — gap → перевод → своё предложение + tap-to-hear (без проверки TTS).
struct TutorPhrasalLadderView: View {
    var contentMode: TutorContentMode = .site

    @Environment(AppSettings.self) private var settings

    @State private var roundKind: VerbKind = .mixed
    @State private var pageIndex = 0
    @State private var pool: [PhrasalEntry] = []
    @State private var pageItems: [PhrasalEntry] = []
    @State private var itemIndex = 0

    @State private var stage: Stage = .gap
    @State private var stageStreak = 0
    @State private var stageUnlocks: Set<Stage> = [.gap]

    @State private var chosen: String?
    @State private var typed = ""
    @State private var feedback: String?
    @State private var passed = false
    @State private var choices: [String] = []

    @State private var speaker: SpeechSpeaker?

    private let pageSize = 5
    private let streakToAdvance = 3

    private enum Stage: Int, CaseIterable, Identifiable, Comparable {
        case gap = 1
        case translate = 2
        case produce = 3
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .gap: return "1 · Пропуск"
            case .translate: return "2 · Перевод"
            case .produce: return "3 · Своё"
            }
        }
        var hint: String {
            switch self {
            case .gap: return "Вставь phrasal в предложение — выбери из списка"
            case .translate: return "По-русски → собери EN-предложение с этим phrasal"
            case .produce: return "Только глагол — напиши своё предложение"
            }
        }
        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private enum VerbKind: String, CaseIterable, Identifiable {
        case mixed, get, take, put, turn, look, come, over, go, make, give, set, bring, find
        var id: String { rawValue }
        var title: String { self == .mixed ? "Смешанный" : rawValue }
        var rootFilter: String? { self == .mixed ? nil : rawValue }
    }

    private var pageCount: Int { max(1, (pool.count + pageSize - 1) / pageSize) }

    private var current: PhrasalEntry? {
        guard pageItems.indices.contains(itemIndex) else { return nil }
        return pageItems[itemIndex]
    }

    private var targetSentence: String {
        guard let p = current else { return "" }
        let ex = p.exampleEn.trimmingCharacters(in: .whitespacesAndNewlines)
        return ex.isEmpty ? "Please \(p.en) carefully on site." : ex
    }

    /// Russian prompt for translate: prefer example sentence, else gloss, else synthetic.
    private var targetRu: String {
        guard let p = current else { return "" }
        return russianPrompt(for: p)
    }

    private var meaningRu: String {
        guard let p = current else { return "" }
        return p.ru.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func russianPrompt(for p: PhrasalEntry) -> String {
        let ex = p.exampleRu.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ex.isEmpty { return ex }
        let gloss = p.ru.trimmingCharacters(in: .whitespacesAndNewlines)
        if !gloss.isEmpty { return gloss }
        return "Составь предложение с «\(p.en)»"
    }

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Лесенка phrasal · от пропуска к своему предложению")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                verbChips
                pageChips
                stagePicker

                if pageItems.isEmpty {
                    Text("Нет phrasal в этой группе")
                        .foregroundStyle(.secondary)
                    Button("Обновить") { reloadPool(resetPage: true) }
                        .buttonStyle(.borderedProminent)
                } else if let p = current {
                    Text(stage.hint)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("\(itemIndex + 1) / \(pageItems.count) · серия \(stageStreak)/\(streakToAdvance)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    stageBody(p)

                    if let feedback {
                        Text(feedback)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(passed ? .green : .orange)
                    }

                    actionRow
                    hearStrip(p)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { NavChrome.dismissKeyboard() }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaPadding(.bottom, 12)
        .navigationTitle("Phrasal · лесенка")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { NavChrome.dismissKeyboard() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Ещё") { reloadPool(resetPage: true) }
            }
        }
        .onAppear {
            TutorBankStore.setMode(contentMode)
            if speaker == nil { speaker = SpeechSpeaker(settings: settings) }
            else { speaker?.updateSettings(settings) }
            if pool.isEmpty { reloadPool(resetPage: true) }
        }
        .onDisappear { speaker?.stop() }
    }

    // MARK: - Chrome

    private var verbChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(VerbKind.allCases) { kind in
                    Button {
                        roundKind = kind
                        reloadPool(resetPage: true)
                    } label: {
                        Text(kind.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                roundKind == kind
                                ? Color.accentColor.opacity(0.2)
                                : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var pageChips: some View {
        Group {
            if !pool.isEmpty {
                HStack(spacing: 8) {
                    Button {
                        guard pageIndex > 0 else { return }
                        pageIndex -= 1
                        applyPage(resetItem: true)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .frame(width: 32, height: 32)
                    }
                    .disabled(pageIndex <= 0)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(0..<pageCount, id: \.self) { i in
                                Button {
                                    pageIndex = i
                                    applyPage(resetItem: true)
                                } label: {
                                    Text(pageChipTitle(i))
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            pageIndex == i
                                            ? Color.accentColor.opacity(0.25)
                                            : Color.secondary.opacity(0.10),
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button {
                        guard pageIndex + 1 < pageCount else { return }
                        pageIndex += 1
                        applyPage(resetItem: true)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .frame(width: 32, height: 32)
                    }
                    .disabled(pageIndex + 1 >= pageCount)
                }

                Text("\(roundKind.title) · стр. \(pageIndex + 1)/\(pageCount) · \(pageItems.count) из \(pool.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var stagePicker: some View {
        HStack(spacing: 8) {
            ForEach(Stage.allCases) { s in
                let unlocked = stageUnlocks.contains(s)
                Button {
                    guard unlocked else { return }
                    stage = s
                    resetItemState()
                } label: {
                    Text(s.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            stage == s
                            ? Color.accentColor.opacity(0.22)
                            : Color.secondary.opacity(unlocked ? 0.12 : 0.06),
                            in: Capsule()
                        )
                        .foregroundStyle(unlocked ? .primary : .tertiary)
                }
                .buttonStyle(.plain)
                .disabled(!unlocked)
            }
        }
    }

    // MARK: - Stages

    @ViewBuilder
    private func stageBody(_ p: PhrasalEntry) -> some View {
        switch stage {
        case .gap:
            tappablePhrase(gapSentence, speakText: targetSentence)
            Text("Варианты")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(spacing: 8) {
                ForEach(choices, id: \.self) { option in
                    HStack(spacing: 8) {
                        Button {
                            speak(option)
                        } label: {
                            Label(option, systemImage: "speaker.wave.2.fill")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            guard !passed else { return }
                            chosen = option
                            checkGap(option, for: p)
                        } label: {
                            Text(chosen == option && passed ? "✓" : "Выбрать")
                                .font(.caption.weight(.bold))
                                .frame(minWidth: 72, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(passed)
                    }
                }
            }
            Text("Тап по фразе — только слушать. «Выбрать» — ответ.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

        case .translate:
            Text("По-русски · переведи на EN")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // Always show the short meaning so the learner knows what the phrasal means.
            if !meaningRu.isEmpty {
                Button {
                    speak(meaningRu)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Значение")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(meaningRu)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
                }
                .buttonStyle(.plain)
            }

            tappablePhrase(russianPrompt(for: p), speakText: russianPrompt(for: p))

            Text("Нужен phrasal: \(p.en)")
                .font(.subheadline.weight(.semibold))
            Button {
                speak(p.en)
            } label: {
                Label(p.en, systemImage: "speaker.wave.2.fill")
            }
            .buttonStyle(.bordered)

            // Do not reveal the EN example until after a pass (it is the answer).
            if passed {
                Text("Образец EN: \(targetSentence)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            TextField("EN предложение", text: $typed, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(passed)
                .submitLabel(.done)
                .onSubmit { NavChrome.dismissKeyboard(); checkTranslate(for: p) }

        case .produce:
            Text("Глагол / phrasal")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Button {
                speak(p.en)
            } label: {
                Text(p.en)
                    .font(.system(size: 28, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button {
                speak(p.ru)
            } label: {
                Text(p.ru)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            TextField("Своё EN предложение с «\(p.en)»", text: $typed, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(passed)
                .submitLabel(.done)
                .onSubmit { NavChrome.dismissKeyboard(); checkProduce(for: p) }
        }
    }

    private func tappablePhrase(_ display: String, speakText: String) -> some View {
        Button {
            speak(speakText)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(display)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Слушать: \(speakText)")
    }

    private func hearStrip(_ p: PhrasalEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Слушать · без проверки")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            FlowHearRow(texts: hearTexts(for: p)) { text in
                speak(text)
            }
        }
        .padding(.top, 8)
    }

    private func hearTexts(for p: PhrasalEntry) -> [String] {
        var out: [String] = []
        switch stage {
        case .gap:
            out.append(p.en)
            let ex = targetSentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ex.isEmpty, ex.lowercased() != p.en.lowercased() { out.append(ex) }
            let gloss = p.ru.trimmingCharacters(in: .whitespacesAndNewlines)
            if !gloss.isEmpty { out.append(gloss) }
        case .translate:
            // RU first — never spoil with the EN example before pass.
            let prompt = russianPrompt(for: p)
            if !prompt.isEmpty { out.append(prompt) }
            let gloss = p.ru.trimmingCharacters(in: .whitespacesAndNewlines)
            if !gloss.isEmpty, gloss.lowercased() != prompt.lowercased() { out.append(gloss) }
            out.append(p.en)
            if passed {
                let ex = targetSentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !ex.isEmpty, ex.lowercased() != p.en.lowercased() { out.append(ex) }
            }
        case .produce:
            out.append(p.en)
            let gloss = p.ru.trimmingCharacters(in: .whitespacesAndNewlines)
            if !gloss.isEmpty { out.append(gloss) }
        }
        if !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    private var actionRow: some View {
        VStack(spacing: 10) {
            if stage != .gap {
                Button("Проверить") {
                    guard let p = current else { return }
                    if stage == .translate { checkTranslate(for: p) }
                    else { checkProduce(for: p) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(passed || typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            if passed {
                Button(itemIndex + 1 >= pageItems.count ? "Стр. дальше / снова" : "Дальше") {
                    advanceAfterPass()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 52)
                .accessibilityHint("Следующее задание лесенки")
            }
        }
    }

    // MARK: - Check / progress

    private func checkGap(_ option: String, for p: PhrasalEntry) {
        let ok = normalize(option) == normalize(p.en)
        passed = ok
        feedback = ok ? "Верно · \(p.en)" : "Нет — нужен «\(p.en)»"
        if ok {
            registerSuccess()
            // Hear the full sentence, then move on — don't leave the board dead
            // with only «Верно» and disabled «Выбрать» (no visible path forward).
            scheduleAdvanceAfterPass(speaking: targetSentence)
        }
    }

    private func checkTranslate(for p: PhrasalEntry) {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let hasPhrasal = t.lowercased().contains(p.en.lowercased())
        let closeToExample = similarity(t, targetSentence) >= 0.55
        let ok = hasPhrasal && (closeToExample || t.split(separator: " ").count >= 3)
        passed = ok
        feedback = ok
            ? "Ок · есть «\(p.en)»"
            : (hasPhrasal ? "Слабо похоже на образец — поправь или слушай EN" : "Вставь «\(p.en)» в предложение")
        if ok {
            registerSuccess()
            scheduleAdvanceAfterPass(speaking: t)
        }
    }

    private func checkProduce(for p: PhrasalEntry) {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let ok = t.lowercased().contains(p.en.lowercased()) && t.split(separator: " ").count >= 3
        passed = ok
        feedback = ok ? "Принято · своё с «\(p.en)»" : "Нужно своё предложение (≥3 слов) с «\(p.en)»"
        if ok {
            registerSuccess()
            scheduleAdvanceAfterPass(speaking: t)
        }
    }

    /// Speak (best-effort), then advance. Safety timer if TTS never finishes (EL key fail).
    private func scheduleAdvanceAfterPass(speaking text: String) {
        let token = itemIndex
        let stageAtPass = stage
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        speaker?.updateSettings(settings)

        let advanceIfStillHere: @MainActor () -> Void = {
            guard self.passed, self.itemIndex == token, self.stage == stageAtPass else { return }
            self.advanceAfterPass()
        }

        if trimmed.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                advanceIfStillHere()
            }
            return
        }

        var didAdvance = false
        let once: @MainActor () -> Void = {
            guard !didAdvance else { return }
            didAdvance = true
            advanceIfStillHere()
        }

        let isRU = trimmed.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        if isRU {
            speaker?.speakRU(trimmed) { Task { @MainActor in once() } }
        } else {
            speaker?.speakEN(trimmed) { Task { @MainActor in once() } }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            once()
        }
    }

    private func registerSuccess() {
        stageStreak += 1
        if stageStreak >= streakToAdvance, let next = Stage(rawValue: stage.rawValue + 1) {
            stageUnlocks.insert(next)
            feedback = (feedback ?? "") + " · открыт \(next.title)"
        }
    }

    private func advanceAfterPass() {
        if itemIndex + 1 < pageItems.count {
            itemIndex += 1
            resetItemState()
            return
        }
        // End of page: wrap or bump stage if unlocked
        if stageStreak >= streakToAdvance, let next = Stage(rawValue: stage.rawValue + 1), stageUnlocks.contains(next) {
            stage = next
            stageStreak = 0
        }
        itemIndex = 0
        pageItems.shuffle()
        resetItemState()
        rebuildChoices()
    }

    private func resetItemState() {
        chosen = nil
        typed = ""
        feedback = nil
        passed = false
        rebuildChoices()
    }

    // MARK: - Pool / page

    private func pageChipTitle(_ i: Int) -> String {
        roundKind == .mixed ? "стр. \(i + 1)" : "\(roundKind.title) \(i + 1)"
    }

    private func reloadPool(resetPage: Bool) {
        TutorBankStore.ensureLoaded()
        let all = TutorBankStore.phrasals
        let next: [PhrasalEntry]
        if let root = roundKind.rootFilter {
            var filtered = all.filter { matches($0, root: root) }
            var seen = Set<String>()
            filtered = filtered.filter { p in
                let k = p.en.lowercased()
                guard !seen.contains(k) else { return false }
                seen.insert(k)
                return true
            }
            filtered.sort { $0.en.lowercased() < $1.en.lowercased() }
            let cap = root == "over" ? 60 : 15
            next = Array(filtered.prefix(cap))
        } else {
            next = Array(all.shuffled().prefix(15))
        }
        pool = next
        if resetPage { pageIndex = 0 }
        pageIndex = min(pageIndex, max(0, pageCount - 1))
        applyPage(resetItem: true)
    }

    private func applyPage(resetItem: Bool) {
        let start = pageIndex * pageSize
        if start < pool.count {
            pageItems = Array(pool[start..<min(start + pageSize, pool.count)])
        } else {
            pageItems = []
        }
        if resetItem {
            itemIndex = 0
            stageStreak = min(stageStreak, streakToAdvance)
            resetItemState()
        }
    }

    private func matches(_ entry: PhrasalEntry, root: String) -> Bool {
        let en = entry.en.lowercased()
        let tokens = en.split(separator: " ").map(String.init)
        let entryRoot = entry.root.lowercased()
        if root == "over" {
            if entryRoot == "over" { return true }
            if en.hasPrefix("over") { return true }
            if let last = tokens.last, last == "over" { return true }
            return false
        }
        if entryRoot == root { return true }
        if let first = tokens.first, first == root { return true }
        return false
    }

    private func rebuildChoices() {
        guard let p = current else { choices = []; return }
        var opts = Set<String>([p.en])
        let bank = TutorBankStore.phrasals.shuffled()
        for e in bank where opts.count < 4 {
            opts.insert(e.en)
        }
        choices = Array(opts).shuffled()
    }

    // MARK: - Speak / helpers

    private func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Cyrillic → RU voice; otherwise EN (tap-to-hear, no checking).
        let isRU = t.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        if isRU {
            speaker?.speakRU(t)
        } else {
            speaker?.speakEN(t)
        }
    }

    private func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func similarity(_ a: String, _ b: String) -> Double {
        let aa = normalize(a).split(separator: " ")
        let bb = normalize(b).split(separator: " ")
        guard !aa.isEmpty, !bb.isEmpty else { return 0 }
        let setB = Set(bb)
        let hit = aa.filter { setB.contains($0) }.count
        return Double(hit) / Double(max(aa.count, bb.count))
    }
}

/// Simple wrapping row of tappable hear chips.
private struct FlowHearRow: View {
    let texts: [String]
    var onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(texts, id: \.self) { text in
                Button {
                    onTap(text)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                        Text(text)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.10))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
