import SwiftUI

/// Поиск корня (take → все take…) + «Погнал» в Пары / Говорить.
struct TutorPhrasalSearchView: View {
    @Environment(AppSettings.self) private var settings

    @State private var query = ""
    @State private var speaker: SpeechSpeaker?
    @State private var note = ""
    @State private var pairsSeed: PhrasalTrainSeed?
    @State private var speakSeed: SpeakTrainSeed?

    private struct PhrasalTrainSeed: Identifiable, Hashable {
        let id = UUID()
        let items: [PhrasalEntry]
    }

    private struct SpeakTrainSeed: Identifiable, Hashable {
        let id = UUID()
        let items: [(en: String, ru: String)]

        static func == (lhs: SpeakTrainSeed, rhs: SpeakTrainSeed) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private var filtered: [PhrasalEntry] {
        TutorBankStore.phrasals(matching: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Корень / слово: take", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)

                HStack(spacing: 8) {
                    Button {
                        pairsSeed = PhrasalTrainSeed(items: Array(filtered.shuffled().prefix(5)))
                    } label: {
                        Text("Погнал · Пары")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(filtered.isEmpty)

                    Button {
                        speakSeed = SpeakTrainSeed(items: filtered.shuffled().prefix(8).map { ($0.en, $0.ru) })
                    } label: {
                        Text("Погнал · Говорить")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(filtered.isEmpty)
                }

                Text("\(filtered.count) phrasal · \(TutorBankStore.contentMode.titleRU)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !note.isEmpty {
                    Text(note).font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(16)

            List {
                ForEach(filtered) { p in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                speak(p.en)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(p.en)
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(.primary)
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .buttonStyle(.plain)
                            Text(p.ru)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if !p.exampleEn.isEmpty {
                                Text(p.exampleEn)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(p.root)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Phrasal поиск")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $pairsSeed) { seed in
            TutorPairsView(mode: .phrasal, seedPhrasals: seed.items)
        }
        .navigationDestination(item: $speakSeed) { seed in
            TutorSpeakDrillView(seedPhrases: seed.items)
        }
        .onAppear {
            speaker = SpeechSpeaker(settings: settings)
            TutorBankStore.ensureLoaded()
        }
        .onDisappear { speaker?.stop() }
    }

    private func speak(_ en: String) {
        speaker?.updateSettings(settings)
        speaker?.speakEN(en) { note = speaker?.statusNote ?? "" }
    }
}
