import SwiftUI
import UIKit

/// NodeForge 1.1 — phrase Loop Mode: speak → STT → fuzzy ≥75% → next.
/// Also accepts seed phrases from Tutor (1.2) without a full Lesson.
struct PhraseLoopView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private let lesson: Lesson?
    private let seedPhrases: [(en: String, ru: String)]?
    private let backTitle: String

    @State private var phrases: [LoopPhrase] = []
    @State private var index = 0
    @State private var phase: Phase = .ready
    @State private var transcript = ""
    @State private var scorePercent = 0
    @State private var capture = TimedSpeechCapture()
    @State private var speaker: SpeechSpeaker?
    @State private var statusNote = ""
    @State private var listenTask: Task<Void, Never>?

    init(lesson: Lesson, backTitle: String = "К плееру") {
        self.lesson = lesson
        self.seedPhrases = nil
        self.backTitle = backTitle
    }

    /// Single / few phrases from Репетитор → Тренажёр.
    init(seedPhrases: [(en: String, ru: String)], backTitle: String = "К репетитору") {
        self.lesson = nil
        self.seedPhrases = seedPhrases
        self.backTitle = backTitle
    }

    private struct LoopPhrase: Identifiable {
        let id: String
        let en: String
        let ru: String
    }

    private enum Phase {
        case ready
        case listening
        case scored      // have transcript + score UI
        case passed
        case failed
        case unclear    // empty / <2 words — not a low % fail
        case finished
    }

    private var current: LoopPhrase? {
        guard phrases.indices.contains(index) else { return nil }
        return phrases[index]
    }

    var body: some View {
        VStack(spacing: 16) {
            progressHeader

            if phase == .finished {
                finishedBlock
            } else if let phrase = current {
                phraseBlock(phrase)
                transcriptBlock
                resultBlock
                controls(for: phrase)
            } else {
                Text("Нет фраз для тренажёра")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("Пропустить") { skip() }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .disabled(phase == .listening || phase == .finished || phase == .scored || current == nil)
        }
        .padding(16)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Тренажёр")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    tearDown()
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                            .font(.body.weight(.semibold))
                        Text(backTitle)
                            .font(.body.weight(.semibold))
                    }
                    .frame(minHeight: 44)
                }
            }
        }
        .onAppear {
            speaker = SpeechSpeaker(settings: settings)
            if let seedPhrases {
                phrases = Self.buildPhrases(fromSeed: seedPhrases)
            } else if let lesson {
                phrases = Self.buildPhrases(from: lesson)
            } else {
                phrases = []
            }
            index = 0
            phase = phrases.isEmpty ? .finished : .ready
            #if DEBUG
            let fails = PhraseSimilarity.selfCheckFailures()
            if !fails.isEmpty {
                print("[PhraseSimilarity] selfCheck FAIL:\n" + fails.joined(separator: "\n"))
            } else {
                print("[PhraseSimilarity] selfCheck OK (3 phrases)")
            }
            #endif
            // Вошёл в тренажёр → сразу слушаем (без «Говорю»).
            if !phrases.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    startListening()
                }
            }
        }
        .onDisappear { tearDown() }
    }

    private var progressHeader: some View {
        HStack {
            Text(phrases.isEmpty ? "0 / 0" : "\(min(index + 1, phrases.count)) / \(phrases.count)")
                .font(.headline)
            Spacer()
            Text(statusNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func phraseBlock(_ phrase: LoopPhrase) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(phrase.en)
                .font(.system(size: 28, weight: .bold))
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Always show full sentence RU under EN (never hide).
            Text(phrase.ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : phrase.ru)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Перевод: \(phrase.ru)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcriptBlock: some View {
        let expected = current?.en ?? ""
        let rawShown: String = {
            if phase == .listening, !capture.partialText.isEmpty {
                return PhraseSimilarity.displayAgainstTarget(capture.partialText, expected: expected)
            }
            return transcript
        }()
        let pair = PhraseSimilarity.displayHeard(rawShown)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Ты сказал: \(pair.heard.isEmpty ? "…" : pair.heard)")
                .font(.body.weight(.medium))
            if let norm = pair.normalized, phase != .listening {
                Text("для сравнения: \(norm)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
    }

    @ViewBuilder
    private var resultBlock: some View {
        switch phase {
        case .listening:
            Text("Слушаю…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .passed:
            Text("\(scorePercent)% · Ок")
                .font(.title2.weight(.bold))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                Text("\(scorePercent)% · Ещё раз")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.orange)
                if let phrase = current {
                    Text("Эталон: \(phrase.en)")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .unclear:
            Text("Не расслышал — ещё раз")
                .font(.title3.weight(.bold))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func controls(for phrase: LoopPhrase) -> some View {
        switch phase {
        case .ready, .failed, .unclear:
            VStack(spacing: 10) {
                // No «Говорю» — auto-listen on enter; Ещё раз restarts mic.
                Button {
                    startListening()
                } label: {
                    Text("Ещё раз")
                        .font(.system(size: 24, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    speakReference(phrase.en)
                } label: {
                    Text("Слушать эталон")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
            }
        case .listening:
            HStack(spacing: 8) {
                Button {
                    capture.finish()
                } label: {
                    Text("Стоп")
                        .font(.system(size: 22, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    capture.cancel()
                    listenTask?.cancel()
                    phase = .unclear
                    statusNote = "Отменено"
                } label: {
                    Text("Отмена")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.bordered)
            }
        case .passed:
            Button {
                advance()
            } label: {
                Text(index + 1 >= phrases.count ? "Готово" : "Дальше")
                    .font(.system(size: 24, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.borderedProminent)
        case .scored, .finished:
            EmptyView()
        }
    }

    private var finishedBlock: some View {
        VStack(spacing: 16) {
            Text("Тренажёр пройден")
                .font(.title2.weight(.bold))
            Text("Можно вернуться назад.")
                .foregroundStyle(.secondary)
            Button {
                tearDown()
                dismiss()
            } label: {
                Text(backTitle)
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func startListening() {
        guard let phrase = current else { return }
        // Release TTS before mic — otherwise STT hears the speaker.
        speaker?.stop()
        ElevenLabsTTS.shared.stop()
        // B12: clear box on retry — no Стоп→Старт to wipe old text.
        capture.cancel()
        transcript = ""
        scorePercent = 0
        statusNote = ""
        phase = .listening
        listenTask?.cancel()
        let targetEN = phrase.en
        listenTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            try? AudioSessionManager.configureForRecording()
            let locale = settings.rememberLocale.rawValue
            let hints = PhraseSimilarity.sttVariants(for: targetEN)
            let text = await capture.captureUntilStopped(
                localeId: locale,
                maxSeconds: 60,
                contextualStrings: hints,
                autoFinishWhen: { PhraseSimilarity.passes(recognized: $0, expected: targetEN) }
            )
            guard !Task.isCancelled else { return }
            if !capture.errorMessage.isEmpty {
                statusNote = capture.errorMessage
            }
            evaluate(text)
        }
    }

    private func evaluate(_ raw: String) {
        guard let phrase = current else { return }
        let collapsed = PhraseSimilarity.displayAgainstTarget(raw, expected: phrase.en)
        transcript = collapsed

        let words = collapsed.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }
        let ok = PhraseSimilarity.passes(recognized: raw, expected: phrase.en)
        let compactPass = ok && PhraseSimilarity.compactKey(collapsed).count >= 3
        // Short STT like «Handover» can be 1 token but still PASS (B4).
        if !compactPass,
           (words.count < 2 || PhraseSimilarity.looksLikeSTTFail(recognized: collapsed, expected: phrase.en)) {
            scorePercent = 0
            phase = .unclear
            statusNote = capture.errorMessage.isEmpty
                ? "Не расслышал — ещё раз (не «плохой английский»)"
                : capture.errorMessage
            scheduleAutoRetry()
            return
        }

        scorePercent = PhraseSimilarity.percent(recognized: raw, expected: phrase.en)

        if ok {
            phase = .passed
            statusNote = "≥75%"
            successHaptic()
            // B6: PASS → stop mic (already finished) → next phrase, no manual Стоп.
            listenTask?.cancel()
            listenTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                advance()
            }
        } else {
            phase = .failed
            statusNote = "Ещё раз ту же фразу"
            scheduleAutoRetry()
        }
    }

    private func scheduleAutoRetry() {
        listenTask?.cancel()
        listenTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            startListening()
        }
    }

    private func advance() {
        speaker?.stop()
        listenTask?.cancel()
        if index + 1 >= phrases.count {
            phase = .finished
            statusNote = ""
            return
        }
        index += 1
        transcript = ""
        scorePercent = 0
        statusNote = ""
        phase = .ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            startListening()
        }
    }

    private func skip() {
        guard phase != .listening else { return }
        speaker?.stop()
        capture.cancel()
        listenTask?.cancel()
        advance()
    }

    private func speakReference(_ en: String) {
        speaker?.updateSettings(settings)
        speaker?.speakEN(en) {
            statusNote = speaker?.statusNote ?? ""
        }
    }

    private func tearDown() {
        listenTask?.cancel()
        listenTask = nil
        capture.cancel()
        speaker?.stop()
    }

    private func successHaptic() {
        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(.success)
        CommandFeedback.acknowledged()
    }

    private static func buildPhrases(from lesson: Lesson) -> [LoopPhrase] {
        var out: [LoopPhrase] = []
        var seen = Set<String>()

        func append(en: String, ru: String) {
            let key = PhraseSimilarity.normalize(en)
            guard !key.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            let ruText = ru.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(LoopPhrase(
                id: "\(out.count)-\(key)",
                en: en,
                ru: ruText.isEmpty ? "—" : ruText
            ))
        }

        for line in lesson.lines where line.isPractice {
            append(en: line.en, ru: line.ru)
        }
        for s in lesson.sayToday {
            append(en: s.en, ru: s.ru)
        }
        if out.isEmpty {
            for line in lesson.lines {
                append(en: line.en, ru: line.ru)
            }
        }
        return out
    }

    private static func buildPhrases(fromSeed seed: [(en: String, ru: String)]) -> [LoopPhrase] {
        var out: [LoopPhrase] = []
        var seen = Set<String>()
        for item in seed {
            let key = PhraseSimilarity.normalize(item.en)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            let ruText = item.ru.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(LoopPhrase(
                id: "\(out.count)-\(key)",
                en: item.en,
                ru: ruText.isEmpty ? "—" : ruText
            ))
        }
        return out
    }
}

#if DEBUG
#Preview("PhraseSimilarity self-check") {
    let fails = PhraseSimilarity.selfCheckFailures()
    return Text(fails.isEmpty ? "selfCheck OK" : fails.joined(separator: "\n"))
        .padding()
}

#Preview("PhraseLoop") {
    NavigationStack {
        PhraseLoopView(
            lesson: LessonLoader.load(named: "lesson-0-1-safe-pass")
                ?? Lesson(
                    id: "preview",
                    titleRu: "Ворота и Safe Pass",
                    titleEn: "Gate & Safe Pass",
                    tags: ["safety", "induction"],
                    sceneRu: "Site induction · первый день.",
                    yourRole: "electrician",
                    partnerRole: "foreman",
                    cards: [
                        LessonCard(en: "Safe Pass", ru: "Safe Pass (карта безопасности)"),
                    ],
                    lines: [
                        LessonLine(en: "Have you got your Safe Pass?", ru: "У тебя есть Safe Pass?", role: "foreman"),
                        LessonLine(en: "Yes. Here's my card.", ru: "Да. Вот моя карта.", role: "electrician", practice: true),
                    ],
                    sayToday: [SayTodayPhrase(en: "Here's my Safe Pass.", ru: "Вот мой Safe Pass.")]
                )
        )
    }
    .environment(AppSettings())
}
#endif
