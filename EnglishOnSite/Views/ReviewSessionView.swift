import SwiftUI
import SwiftData

struct ReviewSessionView: View {
    let items: [LibraryItem]
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var showRU = false
    @State private var finished = false
    @State private var speaker: SpeechSpeaker?

    var body: some View {
        VStack(spacing: 20) {
            if finished {
                Text("Готово. \(items.count) фраз")
                    .font(.title.weight(.bold))
                Button("Закрыть") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else if items.isEmpty {
                Text("Нечего повторять сейчас")
                    .font(.title3)
                Button("Закрыть") { dismiss() }
                    .buttonStyle(.bordered)
            } else {
                Text("\(index + 1) / \(items.count)")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(items[index].en)
                    .font(.system(size: 30, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .minimumScaleFactor(0.7)

                if showRU {
                    Text(items[index].ru)
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("RU скрыт")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                VStack(spacing: 12) {
                    if !showRU {
                        big("Показать") { showRU = true }
                        big("▶ EN") { playCurrent() }
                    } else {
                        big("▶ Прослушать") { playCurrent() }
                        big("Знаю / верно") {
                            LibraryStore.markLearned(items[index], context: modelContext)
                            advance()
                        }
                        Button {
                            LibraryStore.markReviewFailed(items[index], context: modelContext)
                            advance()
                        } label: {
                            Text("Ошибка — снова через 1 день")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(20)
        .navigationTitle("Повтор")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                        Text("Назад")
                    }
                    .font(.body.weight(.semibold))
                    .frame(minHeight: 44)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavChrome.done(action: { dismiss() })
            }
        }
        .onAppear { speaker = SpeechSpeaker(settings: settings) }
        .onDisappear { speaker?.stop() }
    }

    private func big(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
    }

    private func playCurrent() {
        let item = items[index]
        speaker?.updateSettings(settings)
        speaker?.speakEN(item.en)
    }

    private func advance() {
        speaker?.stop()
        if index + 1 < items.count {
            index += 1
            showRU = false
        } else {
            finished = true
        }
    }
}
