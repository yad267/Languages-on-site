import SwiftUI
import SwiftData

/// Phrasal sense → site examples + per-line speak / trainer / library.
struct TutorPhrasalDetailView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let phrasal: SiteTutorPhrasal

    @State private var speaker: SpeechSpeaker?
    @State private var voiceNote = ""
    @State private var libraryNote = ""
    @State private var loopSeed: LoopSeed?

    private struct LoopSeed: Identifiable, Hashable {
        let id = UUID()
        let en: String
        let ru: String
    }

    private struct LineRow: Identifiable {
        let id: String
        let label: String
        let en: String
        let ru: String
    }

    private var rows: [LineRow] {
        var out: [LineRow] = []
        if !phrasal.exampleEn.isEmpty {
            out.append(LineRow(
                id: "example",
                label: "Общий пример",
                en: phrasal.exampleEn,
                ru: phrasal.sentenceRu(forExample: phrasal.exampleEn)
            ))
        }
        let exampleKey = PhraseSimilarity.normalize(phrasal.exampleEn)
        for (i, pair) in phrasal.siteExamplePairs.enumerated() {
            let key = PhraseSimilarity.normalize(pair.en)
            if !exampleKey.isEmpty, key == exampleKey { continue }
            out.append(LineRow(
                id: "site-\(i)",
                label: "На стройке",
                en: pair.en,
                ru: pair.ru
            ))
        }
        let say = phrasal.sayIt.isEmpty ? phrasal.en : phrasal.sayIt
        if !say.isEmpty {
            out.append(LineRow(
                id: "say",
                label: "Say it",
                en: say,
                ru: phrasal.sayItRu.isEmpty ? phrasal.sentenceRu(forExample: say) : phrasal.sayItRu
            ))
        }
        // Dedupe identical EN
        var seen = Set<String>()
        return out.filter { row in
            let key = PhraseSimilarity.normalize(row.en)
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(phrasal.en)
                    .font(.title.weight(.bold))
                if !phrasal.ru.isEmpty {
                    Text(phrasal.ru)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Text("На стройке (Ireland)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if rows.isEmpty {
                    Text("Нет примеров — попроси репетитора ещё раз.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        lineCard(row)
                    }
                }

                if !voiceNote.isEmpty {
                    let bad = voiceNote.contains("ошибка") || voiceNote.contains("выкл") || voiceNote.contains("системный")
                    Text(voiceNote)
                        .font(bad ? .headline.weight(.bold) : .caption.weight(.semibold))
                        .foregroundStyle(bad ? Color.red : Color.orange)
                        .multilineTextAlignment(.leading)
                }
                if !libraryNote.isEmpty {
                    Text(libraryNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Global: still adds SAY IT (default) for convenience
                Button {
                    let en = phrasal.sayIt.isEmpty ? phrasal.en : phrasal.sayIt
                    let ru = phrasal.sayItRu.isEmpty
                        ? (phrasal.ru.isEmpty ? en : phrasal.sentenceRu(forExample: en))
                        : phrasal.sayItRu
                    loopSeed = LoopSeed(en: en, ru: ru)
                } label: {
                    Label("В тренажёр (Say it)", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    saveLibrary()
                } label: {
                    Label("В библиотеку (Say it)", systemImage: "books.vertical")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Phrasal")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Закрыть") { dismiss() }
            }
        }
        .navigationDestination(item: $loopSeed) { seed in
            PhraseLoopView(seedPhrases: [(en: seed.en, ru: seed.ru)], backTitle: "Назад")
        }
        .onAppear {
            if speaker == nil { speaker = SpeechSpeaker(settings: settings) }
        }
    }

    private func lineCard(_ row: LineRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(row.en)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(row.ru.isEmpty ? "—" : row.ru)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    speak(row.en)
                } label: {
                    Label("Озвучить", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)

                Button {
                    loopSeed = LoopSeed(
                        en: row.en,
                        ru: row.ru.isEmpty ? phrasal.ru : row.ru
                    )
                } label: {
                    Text("+ тренажёр")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                markKnown(en: row.en, ru: row.ru.isEmpty ? phrasal.ru : row.ru, tip: phrasal.en)
            } label: {
                Text("Знаю")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func speak(_ en: String) {
        speaker?.updateSettings(settings)
        voiceNote = "…"
        speaker?.speakEN(en) {
            voiceNote = speaker?.statusNote ?? ElevenLabsTTS.shared.lastStatusRU
        }
    }

    private func saveLibrary() {
        let en = phrasal.sayIt.isEmpty ? phrasal.en : phrasal.sayIt
        guard !en.isEmpty else { return }
        let item = LibraryStore.add(
            context: modelContext,
            source: .manual,
            en: en,
            ru: phrasal.sayItRu.isEmpty ? phrasal.ru : phrasal.sayItRu,
            tipRu: phrasal.exampleEn,
            tag: .other,
            transcriptRaw: phrasal.en,
            itemType: .phrasal
        )
        libraryNote = "В Мои фразы: \(en)"
        CommandFeedback.acknowledged()
        Task { await bindAudio(for: item) }
    }

    private func markKnown(en: String, ru: String, tip: String) {
        let item = LibraryStore.setKnown(
            en: en,
            ru: ru,
            tipRu: tip,
            itemType: .phrasal,
            source: .bank,
            known: true,
            context: modelContext
        )
        libraryNote = "Знаю: \(en)"
        CommandFeedback.acknowledged()
        Task { await bindAudio(for: item) }
    }

    private func bindAudio(for item: LibraryItem) async {
        await ElevenLabsTTS.shared.prefetchToDisk(text: item.en, lang: .en, settings: settings)
        let params = settings.elVoiceParams(for: .en)
        let voice = SiteVoiceLang.en.voiceId
        let cache = ElevenLabsAudioCache.fileURL(text: item.en, voice: voice, params: params)
        let preferred = item.audioFileName ?? "\(item.id.uuidString).mp3"
        if let name = LibraryAudioStore.bindFromCacheURL(cache, preferredName: preferred) {
            item.audioFileName = name
            item.audioCacheKey = ElevenLabsAudioCache.cacheKey(text: item.en, voice: voice, params: params)
            try? modelContext.save()
        }
    }
}
