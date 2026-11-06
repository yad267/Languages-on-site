import SwiftUI
import SwiftData
import AVFoundation

/// B17/B20 «Мои фразы»: одна база + «Знаю» + фильтр + привязанное audio.
struct LibraryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LibraryItem.createdAt, order: .reverse) private var items: [LibraryItem]

    @State private var filter: LibraryFilter = .all
    @State private var speaker: SpeechSpeaker?
    @State private var localPlayer: AVAudioPlayer?
    @State private var showReview = false
    @State private var showAdd = false
    @State private var showLearn = false

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all, learning, known, due
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Все"
            case .learning: return "Учу"
            case .known: return "Изученные"
            case .due: return "Повтор"
            }
        }
    }

    private var filtered: [LibraryItem] {
        switch filter {
        case .all: return items
        case .learning: return items.filter(\.isLearningNew)
        case .known: return items.filter(\.known)
        case .due: return items.filter { $0.known && $0.isDue }
        }
    }

    private var dueForReview: [LibraryItem] {
        LibraryStore.dueItems(items, limit: 8)
    }

    var body: some View {
        List {
            Section {
                Picker("Фильтр", selection: $filter) {
                    ForEach(LibraryFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)

                NavigationLink {
                    LearningBankView()
                } label: {
                    Label("Учить: слова / фразовые / предложения", systemImage: "text.book.closed")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }

                Button {
                    showAdd = true
                } label: {
                    Label("Добавить фразу", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }

                Button {
                    showReview = true
                } label: {
                    Label("Повтор (\(dueForReview.count))", systemImage: "rectangle.stack")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(dueForReview.isEmpty)
            }

            if filtered.isEmpty {
                Section {
                    Text("Добавь фразу или отметь «Знаю» в банке. Импорт диалога тоже сюда.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            } else {
                Section("Фразы · \(filtered.count)") {
                    ForEach(filtered, id: \.id) { item in
                        card(item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Мои фразы")
        .onAppear { speaker = SpeechSpeaker(settings: settings) }
        .onDisappear {
            speaker?.stop()
            localPlayer?.stop()
        }
        .navigationDestination(isPresented: $showReview) {
            ReviewSessionView(items: dueForReview)
        }
        .sheet(isPresented: $showAdd) {
            AddMyPhraseView(source: .manual)
                .presentationDragIndicator(.visible)
        }
    }

    private func card(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.en)
                    .font(.title3.weight(.bold))
                Spacer()
                if item.known {
                    Text("Знаю")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            Text(item.ru)
                .font(.body)
                .foregroundStyle(.secondary)
            HStack {
                Text(sourceTitle(item.source))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
                Text(item.itemType.titleRu)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(spacing: 8) {
                Button("▶") { playEN(item) }
                    .buttonStyle(.borderedProminent)
                Button(item.known ? "Забыл" : "Знаю") {
                    if item.known {
                        LibraryStore.unmarkKnown(item, context: modelContext)
                    } else {
                        LibraryStore.markKnown(item, context: modelContext)
                        Task { await ensureAudio(item) }
                    }
                }
                .buttonStyle(.bordered)
                Button("Удалить", role: .destructive) {
                    LibraryStore.delete(item, context: modelContext)
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 6)
    }

    private func sourceTitle(_ s: LibrarySource) -> String {
        switch s {
        case .remember: return "запомни"
        case .translate: return "перевод"
        case .lesson: return "урок"
        case .manual: return "ручная"
        case .importText: return "импорт"
        case .pairsMic: return "пары"
        case .speak: return "говорить"
        case .roleplay: return "roleplay"
        case .bank: return "банк"
        }
    }

    private func playEN(_ item: LibraryItem) {
        if let name = item.audioFileName, LibraryAudioStore.hasFile(name) {
            let url = LibraryAudioStore.fileURL(fileName: name)
            do {
                localPlayer = try AVAudioPlayer(contentsOf: url)
                localPlayer?.prepareToPlay()
                localPlayer?.play()
                return
            } catch {
                // fall through to TTS
            }
        }
        speaker?.updateSettings(settings)
        speaker?.speakEN(item.en)
        Task { await ensureAudio(item) }
    }

    private func ensureAudio(_ item: LibraryItem) async {
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
