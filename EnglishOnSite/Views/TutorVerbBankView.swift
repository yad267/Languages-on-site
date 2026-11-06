import SwiftUI

/// Банк глаголов + Add lemma (виден в генерации).
struct TutorVerbBankView: View {
    @State private var draft = ""
    @State private var ru = ""
    @State private var note = ""
    @State private var verbs: [VerbEntry] = []

    var body: some View {
        List {
            Section("Добавить") {
                TextField("lemma (need, isolate…)", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("RU (опц.)", text: $ru)
                Button("Add") {
                    if TutorBankStore.addVerb(lemma: draft, ru: ru) {
                        note = "Добавлен: \(draft.lowercased())"
                        draft = ""
                        ru = ""
                        reload()
                    } else {
                        note = "Не добавлен (пусто / уже есть)"
                    }
                }
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Банк (\(verbs.count))") {
                ForEach(verbs) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(v.lemma) · \(v.third) / \(v.past)")
                            .font(.headline)
                        Text(v.ru).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Глаголы")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    private func reload() {
        TutorBankStore.reload()
        verbs = TutorBankStore.verbs.sorted { $0.lemma < $1.lemma }
    }
}
