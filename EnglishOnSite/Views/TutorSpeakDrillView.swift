import SwiftUI

/// B1 Говорить: вошёл → сразу Слушаю · EN + RU · STT ≥75% · без кнопки «Говорю».
struct TutorSpeakDrillView: View {
    @Environment(AppSettings.self) private var settings

    /// Optional deck from phrasal search «Погнал».
    var seedPhrases: [(en: String, ru: String)]? = nil

    @State private var phrases: [(en: String, ru: String)] = []
    @State private var index = 0
    @State private var phase: Phase = .ready
    @State private var score = 0
    @State private var heard = ""
    @State private var note = ""
    @State private var capture = TimedSpeechCapture()
    @State private var speaker: SpeechSpeaker?
    @State private var listenTask: Task<Void, Never>?
    @State private var whySeed: String?
    @State private var didAutoStart = false
    /// TTS of the target — mic must stay off until playback finishes.
    @State private var isSpeakingPrompt = false
    @State private var speakHandoffEpoch = 0
    /// DEBUG inject: skip mic after PASS so Simulator smoke does not trip Speech alert.
    @State private var smokeNoMic = false

    private enum Phase { case ready, listening, passed, failed }

    private var current: (en: String, ru: String)? {
        guard phrases.indices.contains(index) else { return nil }
        return phrases[index]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(min(index + 1, max(phrases.count, 1))) / \(max(phrases.count, 1))")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let p = current {
                    Text(p.en)
                        .font(.system(size: 26, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(p.ru)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isSpeakingPrompt {
                        Text("…")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(10)
                        Text("Озвучка эталона… микрофон выкл")
                            .foregroundStyle(.secondary)
                            .font(.subheadline.weight(.semibold))
                    } else if phase == .listening {
                        let shown = PhraseSimilarity.correctOnlyDisplay(
                            recognized: capture.partialText,
                            expected: p.en
                        )
                        Text(shown.isEmpty ? "…" : shown)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(shown.isEmpty ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1.5)
                            )
                        Text("Слушаю… повторяй, пока засчитаем")
                            .foregroundStyle(.secondary)
                            .font(.subheadline.weight(.semibold))
                    } else if phase == .passed {
                        // Only the correct phrase is shown — never a wrong STT dump.
                        Text(heard.isEmpty ? p.en : heard)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.green)
                        Text("Верно · Дальше…").font(.title3.weight(.bold)).foregroundStyle(.green)
                    } else if phase == .failed {
                        // Hide incorrect words; keep listening cycle.
                        Text("…")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Text("Ещё раз ту же фразу")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    if !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text("Нет фраз в банке — добавь phrasal / глаголы")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentMargins(.top, 4, for: .scrollContent)
        .contentMargins(.bottom, 8, for: .scrollContent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                if let p = current {
                    controls(for: p)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 10)
                }
            }
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .safeAreaPadding(.bottom, 12)
        }
        .navigationTitle("Говорить")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $whySeed) { seed in
            TutorWhyView(initialQuestion: seed)
        }
        .onAppear {
            #if DEBUG
            let fails = PhraseSimilarity.selfCheckFailures()
            if !fails.isEmpty {
                print("EOS PhraseSimilarity FAIL: \(fails)")
            } else {
                print("EOS PhraseSimilarity self-check OK")
            }
            let args = ProcessInfo.processInfo.arguments
            // Simulator smoke without mic: inject STT → dedupe + PASS (no SpeechSpeaker / mic).
            if args.contains("-EOSSpeakInjectTurnOff") {
                smokeNoMic = true
                phrases = [(en: "turn off", ru: "выключить"), (en: "ok next", ru: "дальше")]
                didAutoStart = true
                phase = .listening
                heard = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    let raw = "Turn off turn off turn off"
                    let shown = PhraseSimilarity.correctOnlyDisplay(recognized: raw, expected: "turn off")
                    let ok = PhraseSimilarity.passes(recognized: raw, expected: "turn off")
                    evaluate(raw, expected: "turn off")
                    Self.writeSmokeResult(caseName: "turnOffRepeat", heard: shown, passed: ok)
                }
                return
            }
            if args.contains("-EOSSpeakInjectHandover") {
                smokeNoMic = true
                phrases = [(en: "hand over", ru: "передать"), (en: "ok next", ru: "дальше")]
                didAutoStart = true
                phase = .listening
                heard = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    let raw = "handover"
                    let shown = PhraseSimilarity.correctOnlyDisplay(recognized: raw, expected: "hand over")
                    let ok = PhraseSimilarity.passes(recognized: raw, expected: "hand over")
                    evaluate(raw, expected: "hand over")
                    Self.writeSmokeResult(caseName: "handover", heard: shown, passed: ok)
                }
                return
            }
            if args.contains("-EOSSpeakInjectTurnoffCompact") {
                smokeNoMic = true
                phrases = [(en: "turn off", ru: "выключить"), (en: "ok next", ru: "дальше")]
                didAutoStart = true
                phase = .listening
                heard = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    let raw = "turnoff"
                    let shown = PhraseSimilarity.correctOnlyDisplay(recognized: raw, expected: "turn off")
                    let ok = PhraseSimilarity.passes(recognized: raw, expected: "turn off")
                    evaluate(raw, expected: "turn off")
                    Self.writeSmokeResult(caseName: "turnoffCompact", heard: shown, passed: ok)
                }
                return
            }
            #endif
            speaker = SpeechSpeaker(settings: settings)
            TutorBankStore.ensureLoaded()
            if phrases.isEmpty {
                if let seedPhrases, !seedPhrases.isEmpty {
                    phrases = seedPhrases
                } else {
                    phrases = Self.buildDeck()
                }
            }
            guard !didAutoStart, !phrases.isEmpty else { return }
            didAutoStart = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                speakPromptThenListen()
            }
        }
        .onDisappear {
            speakHandoffEpoch &+= 1
            isSpeakingPrompt = false
            listenTask?.cancel()
            capture.cancel()
            speaker?.stop()
        }
    }

    @ViewBuilder
    private func controls(for p: (en: String, ru: String)) -> some View {
        VStack(spacing: 10) {
            if isSpeakingPrompt {
                Text("Слушай эталон…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else if phase == .listening {
                HStack(spacing: 8) {
                    Button("Стоп") { capture.finish() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, minHeight: 52)
                    Button("Отмена", role: .cancel) {
                        capture.cancel()
                        listenTask?.cancel()
                        phase = .failed
                        note = "Отменено — Ещё раз или Back"
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                Button {
                    speakPromptThenListen()
                } label: {
                    Text("Слушать эталон").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            } else if phase == .failed || phase == .ready {
                Button {
                    speakPromptThenListen()
                } label: {
                    Text("Ещё раз")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    speakPromptThenListen()
                } label: {
                    Text("Слушать эталон").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)

                if phase == .failed {
                    Button("Почему?") {
                        whySeed = "почему так: \(p.en)"
                    }
                    .buttonStyle(.bordered)
                }
            } else if phase == .passed {
                Button(index + 1 >= phrases.count ? "Готово" : "Дальше") {
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 52)
            }
        }
    }

    /// TTS first (mic off). Only after full phrase finishes → open STT.
    private func speakPromptThenListen() {
        guard let p = current else { return }
        if smokeNoMic {
            startListen()
            return
        }

        listenTask?.cancel()
        capture.cancel()
        phase = .ready
        heard = ""
        note = ""
        score = 0

        speakHandoffEpoch &+= 1
        let epoch = speakHandoffEpoch
        let target = p.en
        isSpeakingPrompt = true

        speaker?.updateSettings(settings)
        speaker?.speakEN(target) {
            Task { @MainActor in
                guard epoch == speakHandoffEpoch else { return }
                isSpeakingPrompt = false
                note = speaker?.statusNote ?? ""
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard epoch == speakHandoffEpoch else { return }
                guard current?.en == target else { return }
                startListen()
            }
        }
    }

    private func startListen() {
        guard let p = current else { return }
        // Never open mic while TTS is still playing.
        guard !isSpeakingPrompt else { return }
        speaker?.stop()
        ElevenLabsTTS.shared.stop()
        phase = .listening
        // B12: fresh attempt — wipe old transcript before live STT.
        heard = ""
        note = ""
        score = 0
        listenTask?.cancel()
        capture.cancel()
        listenTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            try? AudioSessionManager.configureForRecording()
            var hints = PhraseSimilarity.sttVariants(for: p.en)
            hints.append(contentsOf: p.en.split(separator: " ").map(String.init))
            hints.append(contentsOf: PhraseSimilarity.siteContextualHints)
            let target = p.en
            let text = await capture.captureUntilStopped(
                localeId: settings.rememberLocale.rawValue,
                maxSeconds: 45,
                contextualStrings: hints,
                expectedPhrase: target,
                autoFinishWhen: { PhraseSimilarity.passes(recognized: $0, expected: target) }
            )
            guard !Task.isCancelled else { return }
            evaluate(text, expected: target)
        }
    }

    private func evaluate(_ raw: String, expected: String) {
        let passed = PhraseSimilarity.passes(recognized: raw, expected: expected)
        if passed {
            // Dismiss with the correct phrase only — never flash wrong STT.
            heard = expected
            score = 100
            phase = .passed
            note = ""
            listenTask?.cancel()
            listenTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                advance()
            }
            return
        }
        // Incorrect: clear display, keep same target, listen again.
        heard = ""
        score = 0
        phase = .failed
        note = ""
        listenTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, !smokeNoMic else { return }
            // Mic only — do not TTS over the user finishing trailing words (e.g. hard hat).
            startListen()
        }
    }

    private func advance() {
        speakHandoffEpoch &+= 1
        isSpeakingPrompt = false
        listenTask?.cancel()
        speaker?.stop()
        if index + 1 >= phrases.count {
            index = 0
            if let seedPhrases, !seedPhrases.isEmpty {
                phrases = seedPhrases.shuffled()
            } else {
                phrases = Self.buildDeck()
            }
        } else {
            index += 1
        }
        phase = .ready
        score = 0
        heard = ""
        note = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if smokeNoMic { return }
            speakPromptThenListen()
        }
    }

    #if DEBUG
    private static func writeSmokeResult(caseName: String, heard: String, passed: Bool) {
        let line = "case=\(caseName) heard=\(heard) pass=\(passed)\n"
        print("EOSSpeakSmoke \(line)")
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("eos_speak_smoke.txt")
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

    private static func buildDeck() -> [(en: String, ru: String)] {
        TutorBankStore.ensureLoaded()
        var out: [(en: String, ru: String)] = []
        // B11: prefer example sentences when present; else EN lemma.
        for p in TutorBankStore.corePhrasals.shuffled().prefix(6) {
            let en = p.exampleEn.trimmingCharacters(in: .whitespacesAndNewlines)
            let ru = p.exampleRu.trimmingCharacters(in: .whitespacesAndNewlines)
            if !en.isEmpty {
                out.append((en, ru.isEmpty ? p.ru : ru))
            } else {
                out.append((p.en, p.ru))
            }
        }
        for v in ["need", "put", "sign", "check", "wear"] {
            if let verb = TutorBankStore.verb(named: v) {
                let a = GrammarPatterns.generate(
                    verb: verb,
                    tense: .present,
                    speechAct: .statement,
                    siteTopic: "Safe Pass",
                    subject: .you
                )
                out.append((a.expected[0], a.promptRU))
            }
        }
        return Array(out.prefix(8))
    }
}
