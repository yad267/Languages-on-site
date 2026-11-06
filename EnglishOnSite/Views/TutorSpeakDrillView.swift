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
    /// DEBUG inject: skip mic after PASS so Simulator smoke does not trip Speech alert.
    @State private var smokeNoMic = false

    private enum Phase { case ready, listening, passed, failed }

    private var current: (en: String, ru: String)? {
        guard phrases.indices.contains(index) else { return nil }
        return phrases[index]
    }

    var body: some View {
        VStack(spacing: 16) {
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

                if phase == .listening {
                    let shown = PhraseSimilarity.displayAgainstTarget(capture.partialText, expected: p.en)
                    Text(shown.isEmpty ? "…" : shown)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(shown.isEmpty ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.red.opacity(0.4), lineWidth: 1.5)
                        )
                    Text("Слушаю…")
                        .foregroundStyle(.red)
                        .font(.subheadline.weight(.semibold))
                } else if phase == .passed {
                    Text("\(score)% · Дальше…").font(.title3.weight(.bold)).foregroundStyle(.green)
                } else if phase == .failed {
                    Text("\(score)% · Ещё раз").font(.title3.weight(.bold)).foregroundStyle(.orange)
                    Text("Слышал: \(heard)").font(.caption).foregroundStyle(.secondary)
                }

                if !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }

                controls(for: p)
            } else {
                Text("Нет фраз в банке — добавь phrasal / глаголы")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
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
                    let shown = PhraseSimilarity.displayAgainstTarget(raw, expected: "turn off")
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
                    let shown = PhraseSimilarity.displayAgainstTarget(raw, expected: "hand over")
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
                    let shown = PhraseSimilarity.displayAgainstTarget(raw, expected: "turn off")
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
                startListen()
            }
        }
        .onDisappear {
            listenTask?.cancel()
            capture.cancel()
            speaker?.stop()
        }
    }

    @ViewBuilder
    private func controls(for p: (en: String, ru: String)) -> some View {
        VStack(spacing: 10) {
            if phase == .listening {
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
                    speaker?.updateSettings(settings)
                    speaker?.speakEN(p.en) { note = speaker?.statusNote ?? "" }
                } label: {
                    Text("Слушать эталон").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            } else if phase == .failed || phase == .ready {
                Button {
                    startListen()
                } label: {
                    Text("Ещё раз")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    speaker?.updateSettings(settings)
                    speaker?.speakEN(p.en) { note = speaker?.statusNote ?? "" }
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

    private func startListen() {
        guard let p = current else { return }
        speaker?.stop()
        phase = .listening
        // B12: fresh attempt — wipe old transcript before live STT.
        heard = ""
        note = ""
        score = 0
        listenTask?.cancel()
        capture.cancel()
        listenTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            try? AudioSessionManager.configureForRecording()
            var hints = PhraseSimilarity.sttVariants(for: p.en)
            hints.append(contentsOf: p.en.split(separator: " ").map(String.init))
            hints.append(contentsOf: ["hard hat", "Safe Pass", "hi-vis"])
            let target = p.en
            let text = await capture.captureUntilStopped(
                localeId: settings.rememberLocale.rawValue,
                maxSeconds: 45,
                contextualStrings: hints,
                autoFinishWhen: { PhraseSimilarity.passes(recognized: $0, expected: target) }
            )
            guard !Task.isCancelled else { return }
            evaluate(text, expected: target)
        }
    }

    private func evaluate(_ raw: String, expected: String) {
        heard = PhraseSimilarity.displayAgainstTarget(raw, expected: expected)
        let passed = PhraseSimilarity.passes(recognized: raw, expected: expected)
        if heard.isEmpty
            || (!passed && PhraseSimilarity.looksLikeSTTFail(recognized: heard, expected: expected)) {
            score = PhraseSimilarity.percent(recognized: heard, expected: expected)
            phase = .failed
            note = "Микрофон сбился — ещё раз (не «плохой английский»)"
            listenTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled, !smokeNoMic else { return }
                startListen()
            }
            return
        }
        score = PhraseSimilarity.percent(recognized: heard, expected: expected)
        if passed {
            phase = .passed
            note = "≥75%"
            // B6: PASS → сразу следующая (ту же не дублируем новым item).
            listenTask?.cancel()
            listenTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                advance()
            }
        } else {
            phase = .failed
            note = "Ещё раз ту же фразу"
            listenTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled, !smokeNoMic else { return }
                startListen()
            }
        }
    }

    private func advance() {
        listenTask?.cancel()
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
            startListen()
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
