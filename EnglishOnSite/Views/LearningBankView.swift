import SwiftUI
import SwiftData

/// B20: words / site phrasals / sentences with «Знаю» + filter Все|Учу|Изученные.
struct LearningBankView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Query private var libraryItems: [LibraryItem]

    @State private var kind: LibraryItemType = .word
    @State private var filter: KnownFilter = .all
    @State private var speaker: SpeechSpeaker?

    enum KnownFilter: String, CaseIterable, Identifiable {
        case all, learning, known
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Все"
            case .learning: return "Учу"
            case .known: return "Изученные"
            }
        }
    }

    private var bank: [LearningBankEntry] {
        switch kind {
        case .word: return LearningBankStore.words()
        case .phrasal: return LearningBankStore.sitePhrasals()
        case .sentence: return LearningBankStore.sentences()
        case .myPhrase: return []
        }
    }

    private var filtered: [LearningBankEntry] {
        bank.filter { entry in
            let isKnown = LibraryStore.isKnown(en: entry.en, items: libraryItems)
            switch filter {
            case .all: return true
            case .learning: return !isKnown
            case .known: return isKnown
            }
        }
    }

    private var knownCount: Int {
        bank.filter { LibraryStore.isKnown(en: $0.en, items: libraryItems) }.count
    }

    var body: some View {
        List {
            Section {
                Picker("Тип", selection: $kind) {
                    Text("Слова").tag(LibraryItemType.word)
                    Text("Фразовые").tag(LibraryItemType.phrasal)
                    Text("Предложения").tag(LibraryItemType.sentence)
                }
                .pickerStyle(.segmented)

                Picker("Фильтр", selection: $filter) {
                    ForEach(KnownFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)

                Text("Изучено \(knownCount) / \(bank.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if filtered.isEmpty {
                Section {
                    Text(bank.isEmpty ? "Банк не найден в Resources." : "Пусто в этом фильтре.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(filtered) { entry in
                        row(entry)
                    }
                }
            }
        }
        .navigationTitle("Учить")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { speaker = SpeechSpeaker(settings: settings) }
        .onDisappear { speaker?.stop() }
    }

    private func row(_ entry: LearningBankEntry) -> some View {
        let known = LibraryStore.isKnown(en: entry.en, items: libraryItems)
        return VStack(alignment: .leading, spacing: 8) {
            Text(entry.en)
                .font(.title3.weight(.bold))
            if !entry.ru.isEmpty {
                Text(entry.ru).foregroundStyle(.secondary)
            }
            if !entry.example.isEmpty {
                Text(entry.example)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Button("▶") {
                    speaker?.updateSettings(settings)
                    speaker?.speakEN(entry.en)
                }
                .buttonStyle(.borderedProminent)

                Button(known ? "Изучено ✓" : "Знаю") {
                    toggleKnown(entry, currentlyKnown: known)
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 4)
    }

    private func toggleKnown(_ entry: LearningBankEntry, currentlyKnown: Bool) {
        _ = LibraryStore.setKnown(
            en: entry.en,
            ru: entry.ru,
            tipRu: entry.example,
            itemType: entry.type,
            source: .bank,
            known: !currentlyKnown,
            context: modelContext
        )
        if !currentlyKnown {
            Task {
                await ensureAudio(en: entry.en)
            }
        }
    }

    private func ensureAudio(en: String) async {
        await ElevenLabsTTS.shared.prefetchToDisk(text: en, lang: .en, settings: settings)
        let params = settings.elVoiceParams(for: .en)
        let voice = SiteVoiceLang.en.voiceId
        let cache = ElevenLabsAudioCache.fileURL(text: en, voice: voice, params: params)
        guard let name = LibraryAudioStore.bindFromCacheURL(cache) else { return }
        if let item = LibraryStore.find(normalizedKey: en, context: modelContext) {
            item.audioFileName = name
            item.audioCacheKey = ElevenLabsAudioCache.cacheKey(text: en, voice: voice, params: params)
            try? modelContext.save()
        }
    }
}
