import SwiftUI
import SwiftData
import UIKit

enum TutorPairsMode: String, Hashable {
    case phrasal
    case opposites
}

/// Пары: Phrasal EN-only smart play · Opposites no echo · round speak-all.
struct TutorPairsView: View {
    var mode: TutorPairsMode = .phrasal
    var seedPhrasals: [PhrasalEntry]? = nil

    @Environment(AppSettings.self) private var settings
    @State private var speaker: SpeechSpeaker?

    @State private var leftTiles: [SideTile] = []
    @State private var rightTiles: [SideTile] = []
    @State private var visibleLeft: [SideTile] = []
    @State private var visibleRight: [SideTile] = []
    @State private var pairMeta: [String: PairMeta] = [:]

    @State private var selectedLeftPairId: String?
    @State private var selectedRightPairId: String?
    @State private var matchedIds: Set<String> = []
    @State private var matchedRound: [PairMeta] = []
    @State private var missShake = false
    @State private var progressDone = 0
    @State private var roundSize = 5
    @State private var loopSeed: LoopSeed?
    @State private var lastMatched: PairMeta?
    @State private var lastPlayedEN = ""

    @State private var gloss: GlossState = .hint
    @State private var glossNote = ""
    @State private var glossTask: Task<Void, Never>?
    @State private var prefetchTask: Task<Void, Never>?
    @State private var matchTask: Task<Void, Never>?
    @State private var playEpoch: UInt64 = 0

    @State private var warmingPairId: String?
    @State private var warmingTileIds: Set<String> = []
    @State private var matchBusy = false

    // B13: say a sentence with focused phrasal
    @State private var practiceEN = ""
    @State private var practiceListening = false
    @State private var practiceDraft = ""
    @State private var practiceNote = ""
    @State private var practiceFeedbackEN = ""
    @State private var practiceFeedbackRU = ""
    @State private var practiceOK = false
    @State private var practiceBusy = false
    @State private var showSavePhrase = false
    @State private var practiceCapture = TimedSpeechCapture()
    @State private var practiceTask: Task<Void, Never>?

    struct SideTile: Identifiable, Hashable {
        let id: String
        let pairId: String
        let display: String
        let speakEN: String
        let ru: String
        /// Phrasal: left = RU column; right = EN. Opposites: both EN.
        let isENColumn: Bool
    }

    struct PairMeta: Hashable {
        let pairId: String
        let leftEN: String
        let rightEN: String
        let leftRU: String
        let rightRU: String
        let drillEN: String
        let drillRU: String
    }

    private enum GlossState: Equatable {
        case hint
        case word(en: String, ru: String)
        case pair(enLine: String, ruLine: String)
    }

    private struct LoopSeed: Identifiable, Hashable {
        let id = UUID()
        let phrases: [(en: String, ru: String)]

        static func == (lhs: LoopSeed, rhs: LoopSeed) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private enum Side { case left, right }

    private var allCleared: Bool {
        progressDone >= roundSize && roundSize > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if roundSize == 0 {
                emptyBank
            } else if allCleared {
                roundDone
            } else {
                HStack(alignment: .top, spacing: 12) {
                    tileColumn(tiles: visibleLeft, side: .left)
                    tileColumn(tiles: visibleRight, side: .right)
                }
                .padding(16)
                .offset(x: missShake ? -8 : 0)
                Spacer(minLength: 0)
            }
        }
        .navigationTitle("Пары")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $loopSeed) { seed in
            PhraseLoopView(seedPhrases: seed.phrases, backTitle: "К парам")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Ещё") { dealRound() }
            }
        }
        .onAppear {
            if speaker == nil { speaker = SpeechSpeaker(settings: settings) }
            TutorBankStore.ensureLoaded()
            if leftTiles.isEmpty { dealRound() }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-EOSPairsAutoMatch") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    guard let first = leftTiles.first,
                          let meta = pairMeta[first.pairId],
                          !matchedIds.contains(first.pairId),
                          !matchBusy else { return }
                    beginMatch(pairId: first.pairId, meta: meta, justTappedEN: first.speakEN)
                }
            }
            #endif
        }
        .onDisappear {
            cancelAllAudioAndGlossFetch()
            prefetchTask?.cancel()
            matchTask?.cancel()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Нажмите на пары")
                .font(.title3.weight(.bold))
            Text(mode == .phrasal
                 ? "Phrasal · голос только EN"
                 : "Наоборот · один play на тап")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(progressDone) / \(roundSize)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
            ProgressView(value: Double(progressDone), total: Double(max(roundSize, 1)))
                .tint(.accentColor)
            glossStrip
            if mode == .phrasal, !practiceEN.isEmpty {
                phrasalPracticeStrip
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// B13: mic after EN phrasal tap — Gemini check + Save → Мои фразы.
    private var phrasalPracticeStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Скажи предложение с «\(practiceEN)»")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if practiceListening {
                Text(practiceCapture.partialText.isEmpty ? "…" : practiceCapture.partialText)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                HStack {
                    Button("Стоп") { practiceCapture.finish() }
                        .buttonStyle(.borderedProminent)
                    Button("Отмена", role: .cancel) {
                        practiceCapture.cancel()
                        practiceTask?.cancel()
                        practiceListening = false
                        practiceDraft = ""
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                if !practiceDraft.isEmpty {
                    Text(practiceDraft).font(.subheadline)
                }
                if !practiceFeedbackEN.isEmpty {
                    Text(practiceFeedbackEN).font(.subheadline.weight(.bold))
                    Text(practiceFeedbackRU).font(.caption).foregroundStyle(.secondary)
                }
                if !practiceNote.isEmpty {
                    Text(practiceNote).font(.caption2).foregroundStyle(.orange)
                }
                HStack {
                    Button {
                        Task { await startPhrasalPracticeMic() }
                    } label: {
                        Label(practiceBusy ? "…" : "🎤 Своё предложение", systemImage: "mic.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(practiceBusy || matchBusy)

                    if !practiceFeedbackEN.isEmpty {
                        Button("Сохранить") { showSavePhrase = true }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .sheet(isPresented: $showSavePhrase) {
            AddMyPhraseView(
                initialText: practiceFeedbackEN.isEmpty ? practiceDraft : practiceFeedbackEN,
                source: .pairsMic,
                phrasalHint: practiceEN
            )
            .presentationDragIndicator(.visible)
        }
    }

    private var glossStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch gloss {
            case .hint:
                Text(mode == .phrasal
                     ? "Тап EN — услышишь. RU молчит, пока не пара."
                     : "Тапни слово — услышишь EN и увидишь перевод")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case .word(let en, let ru):
                Text(en)
                    .font(.subheadline.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(ru)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .pair(let enLine, let ruLine):
                Text(enLine)
                    .font(.subheadline.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(ruLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !glossNote.isEmpty {
                Text(glossNote).font(.caption2).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
    }

    private var emptyBank: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)
            Text("Банк пуст").font(.title2.weight(.bold))
            Button("Обновить") { dealRound() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(24)
    }

    private var roundDone: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 12)
            Text("Раунд готов").font(.title2.weight(.bold))
            Text("\(matchedRound.count) пар · сказать все вслух")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let last = lastMatched {
                Text(mode == .phrasal ? last.drillEN : "\(last.leftEN) ↔ \(last.rightEN)")
                    .font(.headline.weight(.bold))
                Text(mode == .phrasal ? last.drillRU : "\(last.leftRU) ↔ \(last.rightRU)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button {
                let phrases = matchedRound.map { meta -> (en: String, ru: String) in
                    if mode == .phrasal {
                        // Prefer example sentence when bank has one.
                        if let p = TutorBankStore.phrasals.first(where: { $0.en == meta.leftEN }),
                           !p.exampleEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let ru = p.exampleRu.isEmpty ? p.ru : p.exampleRu
                            return (p.exampleEn, ru)
                        }
                        return (meta.drillEN, meta.drillRU)
                    }
                    return (meta.drillEN, meta.drillRU)
                }
                guard !phrases.isEmpty else { return }
                loopSeed = LoopSeed(phrases: phrases)
            } label: {
                Label("Сказать вслух · все \(matchedRound.count)", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(matchedRound.isEmpty)
            Button("Ещё раунд") { dealRound() }
                .buttonStyle(.bordered)
            Spacer()
        }
        .padding(24)
    }

    private func tileColumn(tiles: [SideTile], side: Side) -> some View {
        VStack(spacing: 10) {
            ForEach(tiles) { tile in
                let selected = (side == .left && selectedLeftPairId == tile.pairId)
                    || (side == .right && selectedRightPairId == tile.pairId)
                let warming = warmingPairId == tile.pairId || warmingTileIds.contains(tile.id)
                PairTileCell(
                    tile: tile,
                    emphasizeEN: tile.isENColumn || mode == .opposites,
                    isSelected: selected,
                    isWarming: warming,
                    onTap: { handleTileTap(tile: tile, side: side) }
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tap (B2 Phrasal · B7 Opposites)

    private func handleTileTap(tile: SideTile, side: Side) {
        guard !matchBusy else { return }
        glossTask?.cancel()
        glossNote = ""

        switch side {
        case .left: selectedLeftPairId = tile.pairId
        case .right: selectedRightPairId = tile.pairId
        }

        let l = selectedLeftPairId
        let r = selectedRightPairId

        // Match — no separate tap-play (avoids echo / right twice).
        if let l, let r, l == r, let meta = pairMeta[l] {
            beginMatch(pairId: l, meta: meta, justTappedEN: tile.speakEN)
            return
        }

        // Wrong pair
        if let l, let r, l != r {
            setGlossWord(tile)
            // B2: wrong RU → silence. EN / opposites still play the tapped EN word once.
            if !(mode == .phrasal && !tile.isENColumn) {
                playTile(tile)
            }
            withAnimation(.default) { missShake = true }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                missShake = false
                selectedLeftPairId = nil
                selectedRightPairId = nil
            }
            return
        }

        // Single select
        setGlossWord(tile)
        if mode == .phrasal && !tile.isENColumn {
            // RU column: select + gloss only — never TTS Cyrillic / never EN until match.
            return
        }
        if mode == .phrasal, tile.isENColumn {
            practiceEN = tile.speakEN
            practiceDraft = ""
            practiceFeedbackEN = ""
            practiceFeedbackRU = ""
            practiceNote = ""
            practiceOK = false
        }
        playTile(tile)
    }

    private func startPhrasalPracticeMic() async {
        guard mode == .phrasal, !practiceEN.isEmpty, !practiceListening else { return }
        practiceCapture.cancel()
        practiceDraft = ""
        practiceFeedbackEN = ""
        practiceFeedbackRU = ""
        practiceNote = ""
        practiceOK = false
        practiceListening = true
        let hints = PhraseSimilarity.sttVariants(for: practiceEN) + [practiceEN]
        let text = await practiceCapture.captureUntilStopped(
            localeId: settings.rememberLocale.rawValue,
            maxSeconds: 45,
            contextualStrings: hints
        )
        practiceListening = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        practiceDraft = trimmed
        if trimmed.isEmpty || LanguageDetect.classify(trimmed) == .garbage {
            practiceNote = "Не расслышал — скажи ещё раз"
            practiceDraft = ""
            return
        }
        practiceBusy = true
        defer { practiceBusy = false }
        guard settings.geminiEnabledAndReady else {
            practiceNote = "Включи Gemini для проверки"
            return
        }
        do {
            let r = try await GeminiSiteCoachService.shared.reviewPhrasalUse(
                phrasal: practiceEN,
                heard: trimmed
            )
            practiceOK = r.ok
            practiceFeedbackEN = r.en
            practiceFeedbackRU = r.ru
            practiceNote = r.ok ? "Ок" : "Как правильно"
        } catch {
            practiceNote = error.localizedDescription
        }
    }

    /// Match audio: Phrasal = one EN; Opposites = missing side only (≤2, no echo of first tap).
    private func beginMatch(pairId: String, meta: PairMeta, justTappedEN: String) {
        guard !matchBusy, !matchedIds.contains(pairId) else { return }
        matchBusy = true
        lastMatched = meta
        selectedLeftPairId = pairId
        selectedRightPairId = pairId
        setGlossPair(meta)
        CommandFeedback.acknowledged()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        let enA = meta.leftEN.trimmingCharacters(in: .whitespacesAndNewlines)
        let enB = meta.rightEN.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = self.settings
        let prior = lastPlayedEN

        playEpoch &+= 1
        let epoch = playEpoch
        speaker?.stop()
        ElevenLabsTTS.shared.stop()
        speaker?.updateSettings(settings)

        let playList: [String] = {
            if mode == .phrasal || enA == enB {
                return [enA].filter { !$0.isEmpty }
            }
            // Opposites: do not replay the word already heard on first tap.
            var q: [String] = []
            if prior != enA { q.append(enA) }
            if enB != enA, prior != enB { q.append(enB) }
            if q.isEmpty {
                let t = justTappedEN.trimmingCharacters(in: .whitespacesAndNewlines)
                q = [t.isEmpty ? enB : t]
            }
            return q.filter { !$0.isEmpty }
        }()

        matchTask?.cancel()
        matchTask = Task { @MainActor in
            let first = playList.first ?? enA
            if !ElevenLabsTTS.shared.isCached(text: first, lang: .en, settings: settings) {
                warmingPairId = pairId
                await ElevenLabsTTS.shared.prefetchToDisk(text: first, lang: .en, settings: settings)
            }
            for w in playList.dropFirst() {
                if !ElevenLabsTTS.shared.isCached(text: w, lang: .en, settings: settings) {
                    Task { @MainActor in
                        await ElevenLabsTTS.shared.prefetchToDisk(text: w, lang: .en, settings: settings)
                    }
                }
            }

            guard !Task.isCancelled, epoch == playEpoch else {
                warmingPairId = nil
                matchBusy = false
                return
            }
            warmingPairId = nil

            var removed = false
            let removeOnce = {
                guard !removed else { return }
                removed = true
                self.commitRemove(pairId: pairId, meta: meta)
            }

            let safety = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard epoch == self.playEpoch else { return }
                removeOnce()
            }

            let parts = playList.map { (text: $0, english: true) }
            if parts.isEmpty {
                safety.cancel()
                removeOnce()
                matchBusy = false
                return
            }

            lastPlayedEN = ""
            speaker?.speakSequence(parts, onFirstStarted: {
                guard epoch == self.playEpoch else { return }
                safety.cancel()
                removeOnce()
            }, then: {
                guard epoch == self.playEpoch else { return }
                self.captureTTSNote()
                self.matchBusy = false
            })
        }
    }

    private func commitRemove(pairId: String, meta: PairMeta) {
        var next = matchedIds
        next.insert(pairId)
        matchedIds = next
        progressDone = next.count
        lastMatched = meta
        if !matchedRound.contains(where: { $0.pairId == pairId }) {
            matchedRound.append(meta)
        }
        selectedLeftPairId = nil
        selectedRightPairId = nil
        warmingPairId = nil
        withAnimation(.easeInOut(duration: 0.16)) {
            visibleLeft = leftTiles.filter { !matchedIds.contains($0.pairId) }
            visibleRight = rightTiles.filter { !matchedIds.contains($0.pairId) }
        }
    }

    // MARK: - Gloss (no EN↔EN / RU↔RU duplicates for Phrasal)

    private func setGlossWord(_ tile: SideTile) {
        var ru = tile.ru.trimmingCharacters(in: .whitespacesAndNewlines)
        if ru.isEmpty, let bank = TutorBankStore.glossRU(forEN: tile.speakEN) {
            ru = bank
        }
        gloss = .word(en: tile.speakEN, ru: ru.isEmpty ? "…" : ru)
        if !ru.isEmpty, ru != "…" {
            TutorBankStore.cacheGloss(en: tile.speakEN, ru: ru)
        } else if tile.isENColumn || mode == .opposites {
            fetchGlossInBackground(en: tile.speakEN)
        }
    }

    private func setGlossPair(_ meta: PairMeta) {
        glossTask?.cancel()
        glossNote = ""
        if mode == .phrasal || meta.leftEN == meta.rightEN {
            gloss = .pair(enLine: meta.leftEN, ruLine: meta.leftRU)
        } else {
            gloss = .pair(
                enLine: "\(meta.leftEN) ↔ \(meta.rightEN)",
                ruLine: "\(meta.leftRU) ↔ \(meta.rightRU)"
            )
        }
    }

    private func clearGloss() {
        glossTask?.cancel()
        gloss = .hint
        glossNote = ""
    }

    private func fetchGlossInBackground(en: String) {
        glossTask?.cancel()
        glossTask = Task {
            guard settings.geminiEnabledAndReady else { return }
            do {
                let r = try await GeminiSiteCoachService.shared.translateThrowing(
                    text: en,
                    sourceHint: .en
                )
                let ru = r.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled, !ru.isEmpty else { return }
                TutorBankStore.cacheGloss(en: en, ru: ru)
                await MainActor.run {
                    guard case .word(let cur, _) = gloss, cur == en else { return }
                    gloss = .word(en: en, ru: ru)
                }
            } catch {}
        }
    }

    // MARK: - Audio

    private func cancelAllAudioAndGlossFetch() {
        glossTask?.cancel()
        matchTask?.cancel()
        playEpoch &+= 1
        matchBusy = false
        warmingPairId = nil
        warmingTileIds = []
        lastPlayedEN = ""
        speaker?.stop()
        ElevenLabsTTS.shared.stop()
    }

    private func playTile(_ tile: SideTile) {
        let word = tile.speakEN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        // Never feed Cyrillic display into EN TTS.
        if word.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
            return
        }
        playEpoch &+= 1
        let epoch = playEpoch
        speaker?.stop()
        ElevenLabsTTS.shared.stop()
        speaker?.updateSettings(settings)
        lastPlayedEN = word

        let settings = self.settings
        if ElevenLabsTTS.shared.isCached(text: word, lang: .en, settings: settings) {
            speaker?.speakEN(word) {
                guard epoch == self.playEpoch else { return }
                self.captureTTSNote()
            }
            return
        }

        warmingTileIds.insert(tile.id)
        Task { @MainActor in
            await ElevenLabsTTS.shared.prefetchToDisk(text: word, lang: .en, settings: settings)
            warmingTileIds.remove(tile.id)
            guard epoch == playEpoch else { return }
            speaker?.speakEN(word) {
                guard epoch == self.playEpoch else { return }
                self.captureTTSNote()
            }
        }
    }

    private func captureTTSNote() {
        let note = speaker?.statusNote ?? ""
        if note.localizedCaseInsensitiveContains("ошиб")
            || note.localizedCaseInsensitiveContains("нет ключ") {
            glossNote = note
        }
    }

    private func prefetchTableAudio() {
        prefetchTask?.cancel()
        let words = Array(Set((visibleLeft + visibleRight).map(\.speakEN)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }))
        let settings = self.settings
        prefetchTask = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for w in words.prefix(10) {
                    group.addTask { @MainActor in
                        await ElevenLabsTTS.shared.prefetchToDisk(text: w, lang: .en, settings: settings)
                    }
                }
            }
        }
    }

    private func dealRound() {
        TutorBankStore.ensureLoaded()
        cancelAllAudioAndGlossFetch()
        prefetchTask?.cancel()
        clearGloss()

        var metas: [PairMeta] = []
        var left: [SideTile] = []
        var right: [SideTile] = []

        switch mode {
        case .phrasal:
            let pool: [PhrasalEntry]
            if let seedPhrasals, !seedPhrasals.isEmpty {
                pool = Array(seedPhrasals.shuffled().prefix(5))
            } else {
                pool = Array(TutorBankStore.corePhrasals.shuffled().prefix(5))
            }
            for p in pool {
                let pid = p.en
                let drillEN = p.exampleEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? p.en : p.exampleEn
                let drillRU = p.exampleRu.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? p.ru : p.exampleRu
                metas.append(PairMeta(
                    pairId: pid,
                    leftEN: p.en, rightEN: p.en,
                    leftRU: p.ru, rightRU: p.ru,
                    drillEN: drillEN, drillRU: drillRU
                ))
                left.append(SideTile(
                    id: "\(pid)#L", pairId: pid, display: p.ru,
                    speakEN: p.en, ru: p.ru, isENColumn: false
                ))
                right.append(SideTile(
                    id: "\(pid)#R", pairId: pid, display: p.en,
                    speakEN: p.en, ru: p.ru, isENColumn: true
                ))
            }
        case .opposites:
            for o in TutorBankStore.coreOpposites.shuffled().prefix(5) {
                let parts = TutorBankStore.splitOppositeRU(o.ru)
                let leftRU = parts.left ?? TutorBankStore.glossRU(forEN: o.a) ?? o.ru
                let rightRU = parts.right ?? TutorBankStore.glossRU(forEN: o.b) ?? o.ru
                let pid = o.id
                metas.append(PairMeta(
                    pairId: pid,
                    leftEN: o.a, rightEN: o.b,
                    leftRU: leftRU, rightRU: rightRU,
                    drillEN: "\(o.a) / \(o.b)", drillRU: o.ru
                ))
                left.append(SideTile(
                    id: "\(pid)#L", pairId: pid, display: o.a,
                    speakEN: o.a, ru: leftRU, isENColumn: true
                ))
                right.append(SideTile(
                    id: "\(pid)#R", pairId: pid, display: o.b,
                    speakEN: o.b, ru: rightRU, isENColumn: true
                ))
            }
        }

        pairMeta = Dictionary(uniqueKeysWithValues: metas.map { ($0.pairId, $0) })
        roundSize = metas.count
        leftTiles = left
        rightTiles = right.shuffled()
        matchedIds = []
        matchedRound = []
        visibleLeft = leftTiles
        visibleRight = rightTiles
        selectedLeftPairId = nil
        selectedRightPairId = nil
        progressDone = 0
        lastMatched = metas.first
        warmingPairId = nil
        warmingTileIds = []
        matchBusy = false
        lastPlayedEN = ""

        prefetchTableAudio()
    }
}

// MARK: - Full-tile hit area

private struct PairTileCell: View {
    let tile: TutorPairsView.SideTile
    let emphasizeEN: Bool
    let isSelected: Bool
    let isWarming: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(tile.display)
                    .font(emphasizeEN ? .body.weight(.bold) : .subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .padding(.horizontal, 6)
                Group {
                    if isWarming {
                        ProgressView()
                            .controlSize(.small)
                    } else if tile.isENColumn {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 36)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tile.display), \(tile.speakEN)")
        .accessibilityHint("Выбрать и прослушать")
    }
}
