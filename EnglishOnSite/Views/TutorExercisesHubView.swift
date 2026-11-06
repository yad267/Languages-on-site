import SwiftUI

/// Меню упражнений B1–B4 + поиск phrasal + словарь / глаголы.
struct TutorExercisesHubView: View {
    var contentMode: TutorContentMode = .site

    var body: some View {
        List {
            Section {
                NavigationLink {
                    TutorSpeakDrillView()
                } label: {
                    label("Говорить", "Фраза EN + RU · STT ≥75%", "mic.fill")
                }
                NavigationLink {
                    TutorWriteDrillView(contentMode: contentMode)
                } label: {
                    label("Писать в телефоне", "Gap / translate / transform", "keyboard")
                }
                NavigationLink {
                    TutorPairsChooserView()
                } label: {
                    label("Пары", "Phrasal или Наоборот", "rectangle.on.rectangle.angled")
                }
                NavigationLink {
                    TutorVerbFormsView(contentMode: contentMode)
                } label: {
                    label("Формы глагола", contentMode == .site
                         ? "need / put / sign · GrammarPatterns"
                         : "take / get / make · GrammarPatterns", "textformat.abc")
                }
            }
            Section {
                NavigationLink {
                    TutorPhrasalSearchView()
                } label: {
                    label(
                        "Phrasal поиск",
                        "take → все take… · Погнал",
                        "magnifyingglass"
                    )
                }
                NavigationLink {
                    SiteTutorLegacyView()
                } label: {
                    label("Словарь phrasal", "Старый разбор суржик → примеры", "book")
                }
                NavigationLink {
                    TutorVerbBankView()
                } label: {
                    label("Глаголы", "Банк + Add lemma", "plus.circle")
                }
            } header: {
                Text(contentMode.titleRU)
            }
        }
        .navigationTitle("Упражнения")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { TutorBankStore.setMode(contentMode) }
    }

    private func label(_ title: String, _ sub: String, _ icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
    }
}

struct TutorPairsChooserView: View {
    var body: some View {
        List {
            NavigationLink {
                TutorPairsView(mode: .phrasal)
            } label: {
                Label("Phrasal verbs", systemImage: "arrow.left.arrow.right")
            }
            NavigationLink {
                TutorPairsView(mode: .opposites)
            } label: {
                Label("Наоборот", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .navigationTitle("Пары")
        .navigationBarTitleDisplayMode(.inline)
    }
}
