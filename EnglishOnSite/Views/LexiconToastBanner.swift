import SwiftUI

/// Subtle top toast when personal speech lexicon gains a word.
struct LexiconToastBanner: ViewModifier {
    @Bindable var store: SpeechLexiconStore
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if visible, !store.lastToast.isEmpty {
                    Text(store.lastToast)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityLabel(store.lastToast)
                }
            }
            .onChange(of: store.lastToast) { _, newValue in
                guard !newValue.isEmpty else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    visible = true
                }
                Task {
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.25)) { visible = false }
                        store.clearToast()
                    }
                }
            }
    }
}

extension View {
    func lexiconToast(_ store: SpeechLexiconStore = .shared) -> some View {
        modifier(LexiconToastBanner(store: store))
    }
}
