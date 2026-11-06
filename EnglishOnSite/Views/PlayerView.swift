import SwiftUI
import SwiftData

struct PlayerView: View {
    let lesson: Lesson
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var player: LessonPlayer?
    @State private var listener: SpeechCommandListener?
    @State private var capture = TimedSpeechCapture()
    @State private var speaker: SpeechSpeaker?
    @State private var showMicHint = false

    @State private var overlay: OverlayKind = .none
    @State private var translateResult: TranslationResult?
    @State private var rememberResult: RememberBreakdown?
    @State private var savedRememberItem: LibraryItem?
    @State private var statusBanner = ""
    @State private var coachBadge: CoachSourceBadge.Kind = .offline
    @State private var showPhraseLoop = false

    enum OverlayKind {
        case none, translating, translateResult, remembering, rememberResult
    }

    var body: some View {
        Group {
            if let player {
                if overlay == .none {
                    dialogueScreen(player)
                } else {
                    overlayContent(player)
                        .padding(16)
                }
            } else {
                ProgressView("Загрузка…")
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Empty system title when principal toolbar shows RU title (avoids overlap with «Уроки»).
        .navigationTitle(overlay == .none ? "" : overlayNavTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if overlay == .none {
                    NavChrome.backToLessons(dismiss: dismiss)
                } else {
                    NavChrome.done {
                        closeOverlay()
                    }
                }
            }
            ToolbarItem(placement: .principal) {
                if overlay == .none {
                    VStack(spacing: 1) {
                        Text(lesson.titleRu)
                            .font(.headline.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.85)
                        if let titleEn = lesson.titleEn, !titleEn.isEmpty {
                            Text(titleEn)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 220)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if overlay != .none {
                    NavChrome.close(dismiss: dismiss, title: "К урокам")
                }
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .task { await setup() }
        .navigationDestination(isPresented: $showPhraseLoop) {
            PhraseLoopView(lesson: lesson)
        }
        .onDisappear {
            if showPhraseLoop { return }
            listener?.stop()
            capture.cancel()
            speaker?.stop()
            player?.stop()
            if PhoneLessonRelay.shared.player === player {
                PhoneLessonRelay.shared.player = nil
            }
        }
    }

    /// Dialogue step: phrase focus + compact controls (manual next/back).
    /// Bottom panel via `safeAreaInset` so ScrollView never draws bubbles under «Слушать».
    @ViewBuilder
    private func dialogueScreen(_ player: LessonPlayer) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                progressBlock(player)
                if !lesson.cards.isEmpty {
                    DisclosureGroup("Слова урока (\(lesson.cards.count))") {
                        cardsBlockContent
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        chatThread(player)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)

                        // Hard clearance so last bubble+RU can scroll fully above the fixed panel
                        // (safeAreaInset alone still clips tall bubbles / late Lazy layout).
                        Color.clear
                            .frame(height: chatBottomClearance(for: player))
                            .accessibilityHidden(true)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: player.currentIndex) { _, _ in
                    scrollChatToCurrent(player, proxy: proxy)
                }
                .onChange(of: player.sayTodayIndex) { _, _ in
                    scrollChatToCurrent(player, proxy: proxy)
                }
                .onChange(of: player.mode) { _, _ in
                    scrollChatToCurrent(player, proxy: proxy)
                }
                .onAppear {
                    DispatchQueue.main.async {
                        scrollChatToCurrent(player, proxy: proxy, animated: false)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        scrollChatToCurrent(player, proxy: proxy, animated: false)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            dialogueBottomPanel(player)
        }
    }

    /// Approx. height of Listen/nav (+ Тренажёр in sayToday) + breathing room.
    private func chatBottomClearance(for player: LessonPlayer) -> CGFloat {
        // Panel ≈ Listen 52 + nav ~56 + paddings; sayToday adds «Тренажёр» ~52 + gap.
        let base: CGFloat = 168
        let sayTodayExtra: CGFloat = player.mode == .sayToday ? 72 : 0
        let voiceNoteExtra: CGFloat = player.voiceNote.isEmpty ? 0 : 28
        return base + sayTodayExtra + voiceNoteExtra + 24
    }

    /// Fixed Listen / nav / «Тренажёр» — sits in bottom safe area, not over chat text.
    @ViewBuilder
    private func dialogueBottomPanel(_ player: LessonPlayer) -> some View {
        VStack(spacing: 10) {
            if player.mode == .sayToday {
                endOfLessonExtras(player)
            }
            dialogueControls(player)
            voiceHint(player)
            if !player.voiceNote.isEmpty {
                voiceNoteLine(player.voiceNote)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// Keep current bubble fully visible above the bottom panel (anchor bottom of bubble).
    private func scrollChatToCurrent(
        _ player: LessonPlayer,
        proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        let id: String = {
            switch player.mode {
            case .sayToday:
                return chatScrollId(index: player.sayTodayIndex, mode: .sayToday)
            case .lesson, .practiceFeedback:
                return chatScrollId(index: player.currentIndex, mode: player.mode)
            }
        }()
        // Prefer centering in the *visible* area above the inset; clearance spacer
        // lets the bubble sit fully clear of «Слушать» / «Тренажёр».
        let anchor = UnitPoint(x: 0.5, y: 0.55)
        if animated {
            withAnimation(.easeInOut(duration: 0.28)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

    private var overlayNavTitle: String {
        switch overlay {
        case .translating, .translateResult: return "Перевод"
        case .remembering, .rememberResult: return "Запомни"
        case .none: return lesson.titleRu
        }
    }

    private func closeOverlay() {
        capture.cancel()
        overlay = .none
        translateResult = nil
        rememberResult = nil
        savedRememberItem = nil
        coachBadge = .offline
        if let player {
            syncListening(with: player)
        }
    }

    private var cardsBlockContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lesson.cards) { card in
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.en)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(card.ru)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func progressBlock(_ player: LessonPlayer) -> some View {
        VStack(spacing: 6) {
            ProgressView(value: player.progress).tint(.accentColor)
            HStack {
                Text(player.progressText).font(.headline)
                Spacer()
                Text(player.statusText).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func chatScrollId(index: Int, mode: LessonPlayer.Mode) -> String {
        switch mode {
        case .sayToday: return "say-\(index)"
        case .lesson, .practiceFeedback: return "line-\(index)"
        }
    }

    @ViewBuilder
    private func chatThread(_ player: LessonPlayer) -> some View {
        // VStack (not Lazy): scrollTo must find fully laid-out bubbles including RU.
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(lesson.lines.enumerated()), id: \.offset) { idx, line in
                let isCurrent = (player.mode == .lesson || player.mode == .practiceFeedback)
                    && player.currentIndex == idx
                dialogueBubble(
                    role: line.role,
                    en: line.en,
                    ru: line.ru,
                    tipRu: line.tipRu,
                    isCurrent: isCurrent
                )
                .id("line-\(idx)")
            }

            if !lesson.sayToday.isEmpty {
                Text("Скажи сегодня")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.top, 8)
                    .id("say-header")

                ForEach(Array(lesson.sayToday.enumerated()), id: \.offset) { idx, phrase in
                    let isCurrent = player.mode == .sayToday && player.sayTodayIndex == idx
                    dialogueBubble(
                        role: lesson.yourRole,
                        en: phrase.en,
                        ru: phrase.ru,
                        tipRu: nil,
                        isCurrent: isCurrent,
                        forceWorker: true
                    )
                    .id("say-\(idx)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func dialogueBubble(
        role: String,
        en: String,
        ru: String,
        tipRu: String?,
        isCurrent: Bool,
        forceWorker: Bool = false
    ) -> some View {
        let supervisor = forceWorker ? false : lesson.isSupervisorRole(role)
        let align: Alignment = supervisor ? .leading : .trailing
        let accent = supervisor ? Color.orange : Color.accentColor
        let bubbleFill = isCurrent
            ? accent.opacity(0.18)
            : Color(.secondarySystemBackground)
        let border = isCurrent ? accent.opacity(0.85) : Color.clear

        HStack {
            if !supervisor { Spacer(minLength: 36) }
            VStack(alignment: supervisor ? .leading : .trailing, spacing: 6) {
                Text(lesson.roleLabel(for: role))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(accent)
                    .textCase(.uppercase)

                Text(en)
                    .font(.system(size: isCurrent ? 22 : 17, weight: .bold))
                    .multilineTextAlignment(supervisor ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)

                Text(ru)
                    .font(.system(size: isCurrent ? 16 : 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(supervisor ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.showTips, let tipRu, !tipRu.isEmpty, isCurrent {
                    Text(tipRu)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: 320, alignment: supervisor ? .leading : .trailing)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(bubbleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(border, lineWidth: isCurrent ? 2 : 0)
            )
            if supervisor { Spacer(minLength: 36) }
        }
        .frame(maxWidth: .infinity, alignment: align)
        .opacity(isCurrent ? 1 : 0.72)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder
    private func dialogueControls(_ player: LessonPlayer) -> some View {
        VStack(spacing: 10) {
            // Row A — Listen only (manual)
            Button {
                if player.isPlaying && !player.isPaused {
                    player.pause()
                } else {
                    player.play()
                }
                syncListening(with: player)
            } label: {
                Label(
                    player.isPlaying && !player.isPaused ? "Пауза" : "Слушать",
                    systemImage: player.isPlaying && !player.isPaused ? "pause.fill" : "play.fill"
                )
                .font(.system(size: 20, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)

            // Row B — compact nav
            HStack(spacing: 8) {
                compactControl("Назад", systemImage: "chevron.backward", disabled: !player.canSkipBack) {
                    player.skipBack()
                    syncListening(with: player)
                }
                compactControl("Стоп", systemImage: "stop.fill") {
                    player.stop()
                    syncListening(with: player)
                }
                compactControl("Дальше", systemImage: "chevron.forward") {
                    player.skipForward()
                    syncListening(with: player)
                }
                compactControl("Ещё раз", systemImage: "arrow.counterclockwise") {
                    player.repeatCurrentPhrase()
                    syncListening(with: player)
                }
            }
        }
    }

    @ViewBuilder
    private func endOfLessonExtras(_ player: LessonPlayer) -> some View {
        VStack(spacing: 8) {
            Text("Скажи сегодня")
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                listener?.stop()
                player.pause()
                showPhraseLoop = true
            } label: {
                Label("Тренажёр", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }

    private func compactControl(
        _ title: String,
        systemImage: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func voiceNoteLine(_ note: String) -> some View {
        let isProblem = note.contains("ошибка") || note.contains("выкл") || note.contains("системный")
        return Text(note)
            .font(isProblem ? .subheadline.weight(.bold) : .caption.weight(.semibold))
            .foregroundStyle(isProblem ? Color.red : Color.orange)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func overlayContent(_ player: LessonPlayer) -> some View {
        switch overlay {
        case .translating:
            captureTimerUI(title: "Перевод", hint: "Говори фразу…")
        case .translateResult:
            if let r = translateResult {
                translateResultUI(r, player: player)
            }
        case .remembering:
            captureTimerUI(title: "Запомни", hint: "Слушаю объект…")
        case .rememberResult:
            if let r = rememberResult {
                rememberResultUI(r, player: player)
            }
        case .none:
            EmptyView()
        }
    }

    private func captureTimerUI(title: String, hint: String) -> some View {
        VStack(spacing: 24) {
            HStack {
                Text(title).font(.title2.weight(.bold))
                Spacer()
                CoachSourceBadge(kind: coachBadge)
            }
            Text("\(capture.elapsedSeconds)")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(hint).font(.title3.weight(.semibold))
            Text("макс \(capture.secondsLeft) с · жми Готово когда закончил")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !capture.partialText.isEmpty {
                Text(capture.partialText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            big("Готово") {
                capture.finish()
            }
            Button("Отмена") {
                capture.cancel()
                overlay = .none
                coachBadge = .offline
                if let player { syncListening(with: player) }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func translateResultUI(_ r: TranslationResult, player: LessonPlayer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Перевод").font(.headline).foregroundStyle(.secondary)
                Spacer()
                CoachSourceBadge(kind: coachBadge)
            }
            Text(r.sourceText)
                .font(.system(size: 26, weight: .bold))
            Text("→").foregroundStyle(.tertiary)
            Text(r.translatedText)
                .font(.system(size: 28, weight: .bold))
            if !r.tipRu.isEmpty, settings.showTips {
                Text(r.tipRu).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            big("В библиотеку") {
                saveTranslate(r)
                statusBanner = "Сохранено в библиотеку"
            }
            big("Готово") {
                closeOverlay()
            }
            Text("Готово — вернуться к уроку · К урокам — к списку")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func rememberResultUI(_ r: RememberBreakdown, player: LessonPlayer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Запомнил").font(.headline).foregroundStyle(.secondary)
                Spacer()
                CoachSourceBadge(kind: coachBadge)
            }
            Text(r.extractedPhrase)
                .font(.system(size: 28, weight: .bold))
            Text(r.ruMeaning)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(r.tipRu)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let note = r.colloquialNoteRu, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !r.transcriptRaw.isEmpty, r.transcriptRaw != r.extractedPhrase {
                Text("Слышал: \(r.transcriptRaw)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            big("Готово") {
                closeOverlay()
            }
        }
    }

    private func big(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func voiceHint(_ player: LessonPlayer) -> some View {
        VStack(spacing: 2) {
            Text("стоп · дальше · повтори")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            if let listener {
                if !listener.authorizationMessage.isEmpty {
                    Text(listener.authorizationMessage).font(.caption2).foregroundStyle(.orange)
                } else if listener.isListening {
                    Text(listener.lastHeard.isEmpty ? "Слушаю…" : listener.lastHeard)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }

    private func setup() async {
        let p = LessonPlayer(settings: settings)
        p.load(lesson)
        player = p
        PhoneLessonRelay.shared.player = p
        speaker = SpeechSpeaker(settings: settings)

        let l = SpeechCommandListener(settings: settings)
        l.setCommandHandler { action in
            handleCommand(action, player: p)
        }
        listener = l
        await l.requestAuthorizationIfNeeded()
        showMicHint = true

        #if DEBUG
        // Smoke: jump without speaking — verify last bubble clears bottom panel.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-EOSLessonSayToday") {
            p.startSayToday()
            if args.contains("-EOSLessonSay2"), lesson.sayToday.count > 1 {
                p.skipForward()
            }
        } else if args.contains("-EOSLessonLastLine"), lesson.lines.count > 1 {
            for _ in 0..<(lesson.lines.count - 1) {
                p.skipForward()
            }
        }
        #endif
    }

    private func handleCommand(_ action: VoiceCommandAction, player: LessonPlayer) {
        switch action {
        case .translate:
            startTranslate(pausing: player)
        case .remember:
            startRemember(pausing: player)
        case .newLesson:
            // Создание урока — с вкладки Уроки / «Новый урок», не из плеера
            statusBanner = "Новый урок: вкладка Уроки → Новый урок"
        default:
            player.handle(command: action)
            syncListening(with: player)
        }
    }

    private func startTranslate(pausing player: LessonPlayer) {
        listener?.stop()
        player.pause()
        CommandFeedback.acknowledged()
        translateResult = nil
        coachBadge = .offline
        overlay = .translating
        Task {
            let text = await capture.captureUntilStopped(
                localeId: "ru-RU",
                maxSeconds: settings.translateDuration.rawValue
            )
            let recognized: String
            if text.isEmpty {
                recognized = "Can you hit the hall switch?"
                statusBanner = "Симулятор: демо-фраза (пустой mic)"
            } else {
                recognized = text
            }

            let offline = TranslationService.translateOffline(recognized: recognized)
            translateResult = offline
            overlay = .translateResult
            coachBadge = .offline

            if offline.matched {
                speakTranslation(offline)
                return
            }

            coachBadge = .analyzing
            statusBanner = settings.geminiEnabledAndReady
                ? "Офлайн не нашёл — Gemini…"
                : "Gemini выкл / нет ключа"
            let cloud = await TranslationService.translate(recognized: recognized, settings: settings)
            if cloud.viaGemini {
                translateResult = cloud
                coachBadge = .gemini
                statusBanner = ""
                speakTranslation(cloud)
                saveTranslate(cloud)
                return
            }

            translateResult = cloud
            coachBadge = .offline
            statusBanner = cloud.geminiErrorRU ?? "офлайн-разбор"
            speakTranslation(cloud)
            saveTranslate(cloud)
        }
    }

    private func startRemember(pausing player: LessonPlayer) {
        listener?.stop()
        player.pause()
        CommandFeedback.acknowledged()
        rememberResult = nil
        savedRememberItem = nil
        coachBadge = .offline
        overlay = .remembering
        Task {
            let text = await capture.captureUntilStopped(
                localeId: settings.rememberLocale.rawValue,
                maxSeconds: settings.rememberDuration.rawValue
            )
            let recognized: String
            if text.isEmpty {
                recognized = "Flip the main isolator off."
                statusBanner = "Симулятор: демо-фраза (пустой mic)"
            } else {
                recognized = text
            }

            let offline = RememberCaptureService.analyzeOffline(transcript: recognized)
            rememberResult = offline
            let item = LibraryStore.add(
                context: modelContext,
                source: .remember,
                en: offline.sayIt,
                ru: offline.ruMeaning,
                tipRu: offline.tipRu,
                tag: offline.tag,
                transcriptRaw: offline.transcriptRaw
            )
            savedRememberItem = item
            overlay = .rememberResult
            coachBadge = .offline
            playRememberMiniLesson(offline)

            guard settings.geminiEnabledAndReady else { return }
            coachBadge = .analyzing

            let (_, gemini) = await RememberCaptureService.analyze(
                transcript: recognized,
                settings: settings,
                lessonTags: lesson.tags
            )
            guard let gemini else {
                coachBadge = .offline
                if !offline.matched {
                    statusBanner = "офлайн-разбор"
                }
                return
            }

            rememberResult = gemini
            coachBadge = .gemini
            if let item = savedRememberItem {
                LibraryStore.update(
                    item,
                    en: gemini.sayIt,
                    ru: gemini.ruMeaning,
                    tipRu: gemini.tipRu,
                    tag: gemini.tag,
                    context: modelContext
                )
            }

            let sameCore =
                PhraseBank.normalize(offline.sayIt) == PhraseBank.normalize(gemini.sayIt)
                && PhraseBank.normalize(offline.ruMeaning) == PhraseBank.normalize(gemini.ruMeaning)

            speaker?.updateSettings(settings)
            if sameCore {
                var parts: [(String, Bool)] = [(gemini.tipRu, false)]
                if let note = gemini.colloquialNoteRu, !note.isEmpty {
                    parts.append((note, false))
                }
                parts.append(("Повтори: \(gemini.sayIt)", false))
                parts.append((gemini.sayIt, true))
                speaker?.speakSequence(parts)
            } else {
                playRememberMiniLesson(gemini)
            }
        }
    }

    private func speakTranslation(_ r: TranslationResult) {
        speaker?.updateSettings(settings)
        let after: () -> Void = { [self] in
            if let n = speaker?.statusNote, !n.isEmpty {
                statusBanner = n
            }
        }
        if let fallback = r.fallbackSpokenRU, !r.matched {
            speaker?.speakSequence([
                (r.sourceText, !r.sourceIsRussian),
                (fallback, false),
            ], then: after)
        } else {
            speaker?.speakSequence([
                (r.translatedText, r.sourceIsRussian),
            ], then: after)
        }
    }

    private func playRememberMiniLesson(_ r: RememberBreakdown) {
        speaker?.updateSettings(settings)
        speaker?.speakSequence([
            (r.sayIt, true),
            (r.ruMeaning, false),
            (r.tipRu, false),
            ("Повтори: \(r.sayIt)", false),
            (r.sayIt, true),
        ]) {
            if let n = self.speaker?.statusNote, !n.isEmpty {
                self.statusBanner = n
            }
        }
    }

    private func saveTranslate(_ r: TranslationResult) {
        let en = r.sourceIsRussian ? r.translatedText : r.sourceText
        let ru = r.sourceIsRussian ? r.sourceText : r.translatedText
        _ = LibraryStore.add(
            context: modelContext,
            source: .translate,
            en: en == "(перевод позже)" ? r.sourceText : en,
            ru: ru,
            tipRu: r.tipRu,
            tag: r.tag,
            transcriptRaw: r.sourceText
        )
    }

    private func syncListening(with player: LessonPlayer) {
        guard let listener else { return }
        listener.updateSettings(settings)
        player.updateSettings(settings)
        speaker?.updateSettings(settings)

        if overlay != .none { return }

        if player.isPlaying && !player.isPaused && player.mode != .practiceFeedback {
            listener.start()
        } else {
            listener.stop()
        }
    }
}
