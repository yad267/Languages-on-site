import SwiftUI

/// B14: root tab «Фразовые» — site|general + search / pairs / speak in one tap.
struct PhrasalHubView: View {
    @State private var contentMode: TutorContentMode = .site

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Режим", selection: $contentMode) {
                    ForEach(TutorContentMode.allCases) { mode in
                        Text(mode.titleRU).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .onChange(of: contentMode) { _, mode in
                    TutorBankStore.setMode(mode)
                }

                TutorPhrasalSearchView()
            }
            .navigationTitle("Фразовые")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { TutorBankStore.setMode(contentMode) }
        }
    }
}
