import SwiftUI

/// Режим «Поговорить»: практика take-за-take, пока STT не поймает эталон. Без ругани за STT.
struct TutorTalkView: View {
    @Environment(AppSettings.self) private var settings

    let initialTopic: String?
    var contentMode: TutorContentMode = .site
    var onWhy: (String) -> Void

    @State private var turns: [CoachTurn] = []
    @State private var draft = ""
    @State private var isBusy = false
    @State private var isListening = false
    @State private var awaitingReview = false
    @State private var sttHint = ""
    @State private var liveSimilarity: Double = 0
    @State private var errorMessage: String?
    @State private var showNoKeyAlert = false
    @State private var speakReplies = true
    @State private var voiceNote = ""
    @State private var capture = TimedSpeechCapture()
    @State private var speaker: SpeechSpeaker?
    @State private var lastWhySeed = ""
    @State private var didBootstrap = false
    @State private var pinnedSayNowEN = ""
    @State private var pinnedSayNowRU = ""
    /// Until this phrase is credited, don't let coach/topic swap the target.
    @State private var waitingForPass = false
    /// Отправить below threshold only after owner taps Править.
    @State private var didTapEdit = false
    /// Auto-start mic once per pinned target (no «Говорю»).
    @State private var autoListenTarget: String = ""
    @FocusState private var draftFocused: Bool

    private struct CoachTurn: Identifiable {
        let id = UUID()
        let isUser: Bool
        let text: String
        let sayNowEN: String?
        let sayNowRU: String?
        let isMutedNote: Bool
    }

    private var displayedSimilarity: Double {
        if isListening {
            let partial = capture.partialText
            guard !partial.isEmpty, !pinnedSayNowEN.isEmpty else { return liveSimilarity }
            return PhraseSimilarity.talkScore(recognized: partial, expected: pinnedSayNowEN)
        }
        guard !draft.isEmpty, !pinnedSayNowEN.isEmpty else { return liveSimilarity }
        return PhraseSimilarity.talkScore(recognized: draft, expected: pinnedSayNowEN)
    }

    private var passesCurrent: Bool {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !pinnedSayNowEN.isEmpty else { return false }
        return PhraseSimilarity.passesTalk(recognized: t, expected: pinnedSayNowEN)
    }

    private var canSend: Bool {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isBusy && !isListening && !t.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(turns) { turn in
                            turnBubble(turn).id(turn.id)
                        }
                        if isBusy {
                            ProgressView("Коуч думает…")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("busy")
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { NavChrome.dismissKeyboard() }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: turns.count) { _, _ in
                    if let last = turns.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if !pinnedSayNowEN.isEmpty {
                pinnedTargetCard
            }

            if isListening || awaitingReview {
                attemptCard
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            if !voiceNote.isEmpty {
                Text(voiceNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            quickBar
            composerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
        }
        .navigationTitle("Поговорить")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $speakReplies) {
                    Image(systemName: speakReplies ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .toggleStyle(.button)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { NavChrome.dismissKeyboard(); draftFocused = false }
                    .fontWeight(.semibold)
            }
        }
        .alert("Нужен Gemini", isPresented: $showNoKeyAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Вставь ключ Gemini в Настройках и включи toggle.")
        }
        .onAppear {
            if speaker == nil { speaker = SpeechSpeaker(settings: settings) }
            TutorBankStore.setMode(contentMode)
            guard !didBootstrap else { return }
            didBootstrap = true
            Task { await bootstrap() }
            #if DEBUG
            // -EOSTutorFakeSTT "I save myself pass card here" → review card without mic
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-EOSTutorFakeSTT"), args.index(after: i) < args.endIndex {
                let fake = args[args.index(after: i)]
                // Wait until bootstrap pins a target so similarity is meaningful.
                Task {
                    for _ in 0..<40 {
                        if !pinnedSayNowEN.isEmpty { break }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    applyStopResult(fake)
                }
            }
            #endif
        }
        .onDisappear {
            capture.cancel()
            speaker?.stop()
        }
        .onChange(of: capture.partialText) { _, partial in
            guard isListening, !pinnedSayNowEN.isEmpty, !partial.isEmpty else { return }
            liveSimilarity = PhraseSimilarity.talkScore(recognized: partial, expected: pinnedSayNowEN)
        }
    }

    // MARK: - Cards

    private var pinnedTargetCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Скажи сейчас")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(pinnedSayNowEN)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            if !pinnedSayNowRU.isEmpty {
                Text(pinnedSayNowRU)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if waitingForPass {
                Text("Повторяй, пока засчитаем")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Button {
                speakEN(pinnedSayNowEN)
            } label: {
                Label("Слушать EN", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(isListening || isBusy || pinnedSayNowEN.isEmpty)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12))
        .overlay(alignment: .topTrailing) {
            if isListening {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("Слушаю…")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.red)
                }
                .padding(10)
            }
        }
    }

    private var attemptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isListening ? "Вы говорите…" : "Распознано")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            similarityBar

            if isListening {
                Text(capture.partialText.isEmpty ? "…" : capture.partialText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(capture.partialText.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.red.opacity(0.45), lineWidth: 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                    )
                Text("\(capture.elapsedSeconds) с")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    Button("Стоп") { capture.finish() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    Button("Ещё раз") {
                        Task { await restartListeningNow() }
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            } else {
                TextField("Текст попытки…", text: $draft, axis: .vertical)
                    .lineLimit(2...6)
                    .font(.title3.weight(.semibold))
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                passesCurrent ? Color.green : Color.orange.opacity(0.7),
                                lineWidth: 1.5
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                    )
                    .focused($draftFocused)
                    .disabled(isBusy)
                    .onChange(of: draft) { _, new in
                        guard !pinnedSayNowEN.isEmpty else { return }
                        liveSimilarity = PhraseSimilarity.talkScore(recognized: new, expected: pinnedSayNowEN)
                    }

                let reviewHint: String = {
                    if passesCurrent {
                        let pct = Int((displayedSimilarity * 100).rounded())
                        return "Засчитать? (\(pct)%)"
                    }
                    return sttHint
                }()
                if !reviewHint.isEmpty {
                    Text(reviewHint)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(passesCurrent ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Primary practice CTA: keep saying until pass
                if !passesCurrent {
                    Button {
                        Task { await retrySamePhrase() }
                    } label: {
                        Text("Ещё раз говорить")
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                } else {
                    Button {
                        Task { await creditAndAdvance() }
                    } label: {
                        Text("Засчитать")
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isBusy)
                }

                HStack(spacing: 8) {
                    if passesCurrent {
                        Button {
                            Task { await creditAndAdvance() }
                        } label: {
                            Text("Отправить")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                    } else {
                        // Manual send only after Править (owner fixed STT by hand)
                        Button {
                            Task { await submitEdited() }
                        } label: {
                            Text("Отправить")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canSend || isBusy || !didTapEdit)
                    }

                    Button {
                        didTapEdit = true
                        draftFocused = true
                    } label: {
                        Text("Править")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var similarityBar: some View {
        let pct = Int((displayedSimilarity * 100).rounded())
        let ok = displayedSimilarity >= PhraseSimilarity.talkPassThreshold
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Похожесть")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(pct)%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ok ? Color.green : Color.secondary)
            }
            ProgressView(value: min(max(displayedSimilarity, 0), 1))
                .tint(ok ? .green : .orange)
        }
    }

    private var quickBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("Подскажи фразу") {
                    Task { await askHint() }
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || isListening || waitingForPass)

                Button("Почему?") {
                    let seed = lastWhySeed.isEmpty
                        ? (pinnedSayNowEN.isEmpty ? "почему так говорят на объекте?" : "почему: \(pinnedSayNowEN)")
                        : lastWhySeed
                    onWhy(seed)
                }
                .buttonStyle(.bordered)

                ForEach(talkTopicChips.prefix(6), id: \.self) { topic in
                    Button(topic) {
                        Task { await send(userText: "Давай тему: \(topic)", hideUserBubble: false, meta: .topicPick) }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption.weight(.semibold))
                    .disabled(isBusy || isListening || waitingForPass)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var composerBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if !awaitingReview && !isListening {
                TextField("Или напиши без микрофона…", text: $draft, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isBusy)
                    .focused($draftFocused)
            }

            // Mic = Стоп while listening; otherwise restart take (no separate «Говорю» gate).
            Button {
                Task {
                    if isListening {
                        capture.finish()
                    } else {
                        await startListening()
                    }
                }
            } label: {
                Image(systemName: isListening ? "stop.circle.fill" : "mic.fill")
                    .font(.title)
                    .frame(width: 44, height: 44)
                    .foregroundStyle(isListening ? Color.red : Color.accentColor)
            }
            .disabled(isBusy)
            .accessibilityLabel(isListening ? "Стоп" : "Ещё раз")

            if !awaitingReview && !isListening {
                Button {
                    Task {
                        if waitingForPass {
                            await submitEdited()
                        } else {
                            let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            draft = ""
                            await send(userText: t, hideUserBubble: false, meta: .normal)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(isBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func turnBubble(_ turn: CoachTurn) -> some View {
        if turn.isUser {
            HStack {
                Spacer(minLength: 40)
                Text(turn.text)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.18))
                    )
            }
        } else if turn.isMutedNote {
            Text(turn.text)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(turn.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let en = turn.sayNowEN, !en.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Скажи сейчас")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(en)
                            .font(.title3.weight(.bold))
                        if let ru = turn.sayNowRU, !ru.isEmpty {
                            Text(ru)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            speakEN(en)
                        } label: {
                            Label("Слушать EN", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }

    private var talkTopicChips: [String] {
        contentMode == .site
            ? Array((["Safe Pass", "PPE", "Tools"] + TutorTopicBank.makeChips()).prefix(8))
            : ["Home", "Food", "Travel", "Shopping", "Feelings", "Phone", "Friends"]
    }

    // MARK: - Actions

    private enum SendMeta { case normal, topicPick, bootstrap, hint, localPass }

    private func bootstrap() async {
        let opener: String
        if let topic = initialTopic?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty {
            opener = "START topic=\(topic)"
        } else {
            opener = "START"
        }
        await send(userText: opener, hideUserBubble: true, meta: .bootstrap)
    }

    private func askHint() async {
        guard !waitingForPass else { return }
        await send(userText: "HINT", hideUserBubble: true, meta: .hint)
    }

    private func startListening() async {
        if isListening {
            capture.finish()
            return
        }
        speaker?.stop()
        ElevenLabsTTS.shared.stop()
        errorMessage = nil
        sttHint = ""
        draft = ""
        liveSimilarity = 0
        didTapEdit = false
        awaitingReview = false
        isListening = true
        let hints = contextualHints()
        let locale = settings.rememberLocale == .enGB ? "en-GB" : "en-IE"
        let text = await capture.captureUntilStopped(
            localeId: locale,
            maxSeconds: 45,
            contextualStrings: hints
        )
        isListening = false
        applyStopResult(text)
    }

    /// Cancel current take and immediately start a new one (same target).
    private func restartListeningNow() async {
        capture.cancel()
        isListening = false
        draft = ""
        sttHint = ""
        liveSimilarity = 0
        awaitingReview = false
        // Brief pause so audio engine can restart cleanly.
        try? await Task.sleep(nanoseconds: 150_000_000)
        await startListening()
    }

    private func applyStopResult(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = trimmed
        awaitingReview = true
        liveSimilarity = pinnedSayNowEN.isEmpty
            ? 0
            : PhraseSimilarity.talkScore(recognized: trimmed, expected: pinnedSayNowEN)

        if trimmed.isEmpty {
            sttHint = "Не расслышал. Ещё раз"
            appendMutedNoteOnce()
            return
        }
        if !pinnedSayNowEN.isEmpty {
            if PhraseSimilarity.passesTalk(recognized: trimmed, expected: pinnedSayNowEN) {
                let pct = Int((liveSimilarity * 100).rounded())
                sttHint = "Засчитать? (\(pct)%)"
                return
            }
            if PhraseSimilarity.looksLikeSTTFail(recognized: trimmed, expected: pinnedSayNowEN)
                || liveSimilarity < PhraseSimilarity.talkPassThreshold {
                sttHint = liveSimilarity < 0.35
                    ? "Микрофон сбился — скажи ещё раз"
                    : "Не расслышал. Ещё раз"
                appendMutedNoteOnce()
                return
            }
        }
        sttHint = "Не расслышал. Ещё раз"
        appendMutedNoteOnce()
    }

    private func appendMutedNoteOnce() {
        // At most one quiet line — no coach jokes, no English shame.
        if turns.last?.isMutedNote == true { return }
        turns.append(CoachTurn(
            isUser: false,
            text: "попытка, не зачтено",
            sayNowEN: nil,
            sayNowRU: nil,
            isMutedNote: true
        ))
    }

    private func retrySamePhrase() async {
        draft = ""
        sttHint = ""
        liveSimilarity = 0
        didTapEdit = false
        awaitingReview = false
        errorMessage = nil
        await startListening()
    }

    /// Credited take → coach may advance phrase.
    private func creditAndAdvance() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard pinnedSayNowEN.isEmpty || PhraseSimilarity.passesTalk(recognized: text, expected: pinnedSayNowEN) else {
            sttHint = "Ещё не похоже — Ещё раз говорить или поправь"
            return
        }
        awaitingReview = false
        draft = ""
        sttHint = ""
        waitingForPass = false
        turns.append(CoachTurn(
            isUser: false,
            text: "Засчитано",
            sayNowEN: nil,
            sayNowRU: nil,
            isMutedNote: false
        ))
        await send(
            userText: "PASS: \(text)",
            hideUserBubble: false,
            displayUser: text,
            meta: .localPass
        )
    }

    /// Owner edited STT by hand and presses Отправить → force credit (spec).
    private func submitEdited() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            sttHint = "Не расслышал. Ещё раз"
            return
        }
        // After Править, Отправить credits even below 0.65 — owner owns the fix.
        awaitingReview = false
        draft = ""
        sttHint = ""
        waitingForPass = false
        turns.append(CoachTurn(
            isUser: false,
            text: "Засчитано",
            sayNowEN: nil,
            sayNowRU: nil,
            isMutedNote: false
        ))
        await send(
            userText: "PASS: \(text)",
            hideUserBubble: false,
            displayUser: text,
            meta: .localPass
        )
    }

    private func send(
        userText: String,
        hideUserBubble: Bool,
        displayUser: String? = nil,
        meta: SendMeta
    ) async {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard settings.geminiEnabledAndReady else {
            showNoKeyAlert = true
            errorMessage = "Нет ключа Gemini в Настройках"
            return
        }

        errorMessage = nil
        isBusy = true
        if !hideUserBubble {
            turns.append(CoachTurn(
                isUser: true,
                text: displayUser ?? text,
                sayNowEN: nil,
                sayNowRU: nil,
                isMutedNote: false
            ))
        }

        let coachInput: String = {
            switch meta {
            case .localPass:
                return """
                LEARNER_PASS (similarity ≥65%). Reply briefly «Засчитано» vibe in RU, then give the NEXT say_now_en (new micro-task). Do not keep the old target.
                Heard: \(displayUser ?? text)
                Previous target: \(pinnedSayNowEN)
                """
            case .bootstrap, .hint, .topicPick, .normal:
                return text
            }
        }()

        do {
            var historyPayload = turns.map { ($0.isUser, $0.text) }
            if meta == .localPass, let displayUser {
                historyPayload = turns.filter { !$0.isMutedNote }.suffix(10).map { ($0.isUser, $0.text) }
                // Ensure last learner line is the credited phrase
                if historyPayload.last?.0 != true || historyPayload.last?.1 != displayUser {
                    historyPayload.append((true, displayUser))
                }
            }
            let reply = try await GeminiSiteCoachService.shared.coachTalk(
                history: historyPayload,
                userText: coachInput,
                topicHint: initialTopic,
                contentMode: contentMode
            )
            lastWhySeed = reply.whySeed
            // Only update pinned target from coach when not mid-fail practice,
            // or after a pass / bootstrap / topic change.
            let allowNewTarget = (meta == .localPass || meta == .bootstrap || meta == .hint || meta == .topicPick || !waitingForPass)
            if allowNewTarget, !reply.sayNowEN.isEmpty {
                waitingForPass = true
                let newEN = reply.sayNowEN
                pinnedSayNowRU = reply.sayNowRU
                pinnedSayNowEN = newEN
                // Auto-listen after pin; delay longer if TTS will play (don't hear the speaker).
                let delayNs: UInt64 = speakReplies ? 2_400_000_000 : 450_000_000
                autoListenTarget = newEN
                Task {
                    if speakReplies { speakEN(newEN) }
                    try? await Task.sleep(nanoseconds: delayNs)
                    speaker?.stop()
                    guard !isListening, !isBusy, pinnedSayNowEN == newEN, waitingForPass else { return }
                    await startListening()
                }
            }
            turns.append(CoachTurn(
                isUser: false,
                text: reply.coachRU,
                sayNowEN: allowNewTarget && !reply.sayNowEN.isEmpty ? reply.sayNowEN : nil,
                sayNowRU: allowNewTarget && !reply.sayNowRU.isEmpty ? reply.sayNowRU : nil,
                isMutedNote: false
            ))
        } catch let e as GeminiRequestError {
            errorMessage = e.shortRU
            turns.append(CoachTurn(
                isUser: false,
                text: "Сбой: \(e.shortRU). Попробуй ещё раз.",
                sayNowEN: nil,
                sayNowRU: nil,
                isMutedNote: false
            ))
        } catch {
            errorMessage = "Нет сети / таймаут"
            turns.append(CoachTurn(
                isUser: false,
                text: "Нет сети. Проверь связь и повтори.",
                sayNowEN: nil,
                sayNowRU: nil,
                isMutedNote: false
            ))
        }
        isBusy = false
    }

    private func contextualHints() -> [String] {
        var hints: [String] = []
        if !pinnedSayNowEN.isEmpty {
            hints.append(pinnedSayNowEN)
            // Full phrase + every word (incl. short: I / my / have)
            let words = pinnedSayNowEN
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            hints.append(contentsOf: words)
            // Bigrams
            if words.count >= 2 {
                for i in 0..<(words.count - 1) {
                    hints.append("\(words[i]) \(words[i + 1])")
                }
            }
        }
        hints += [
            "Safe Pass", "hard hat", "hi-vis", "hi vis", "card", "here", "have", "my",
            "I have", "my Safe Pass", "Pass card", "card here",
        ]
        return hints
    }

    private func speakEN(_ en: String) {
        speaker?.updateSettings(settings)
        voiceNote = "…"
        speaker?.speakEN(en) {
            voiceNote = speaker?.statusNote ?? ElevenLabsTTS.shared.lastStatusRU
        }
    }
}
