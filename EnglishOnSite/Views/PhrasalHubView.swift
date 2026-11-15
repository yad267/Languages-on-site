import SwiftUI

/// Tab «Фразовые»: Onsite | Regular → Duolingo pairs; family (get/take/…/over) or mixed.
/// Sub-menu: verb group + page (5 phrases/page, ~2–3 pages when ≥10–15 items).
struct PhrasalHubView: View {
    /// When true (Репетитор → Пары), reuse parent NavigationStack — same board as tab «Фразовые».
    var embedded: Bool = false
    var navigationTitleText: String = "Фразовые"

    @State private var track: PhrasalTrack = .onsite
    @State private var roundKind: PhrasalRoundKind = .mixed
    @State private var pageIndex: Int = 0
    @State private var pool: [PhrasalEntry] = []
    @State private var seedPhrasals: [PhrasalEntry] = []

    private let pageSize = 5

    init(embedded: Bool = false, navigationTitleText: String = "Фразовые", initialSite: Bool? = nil) {
        self.embedded = embedded
        self.navigationTitleText = navigationTitleText
        if let initialSite {
            _track = State(initialValue: initialSite ? .onsite : .regular)
        }
    }

    private enum PhrasalTrack: String, CaseIterable, Identifiable {
        case onsite, regular
        var id: String { rawValue }
        var title: String {
            switch self {
            case .onsite: return "Onsite"
            case .regular: return "Regular"
            }
        }
        var bankMode: TutorContentMode {
            switch self {
            case .onsite: return .site
            case .regular: return .general
            }
        }
    }

    private enum PhrasalRoundKind: String, CaseIterable, Identifiable {
        case mixed, get, take, put, turn, look, come, over
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mixed: return "Смешанный"
            case .get: return "get"
            case .take: return "take"
            case .put: return "put"
            case .turn: return "turn"
            case .look: return "look"
            case .come: return "come"
            case .over: return "over"
            }
        }
        var rootFilter: String? {
            switch self {
            case .mixed: return nil
            default: return rawValue
            }
        }
    }

    private var pageCount: Int {
        max(1, (pool.count + pageSize - 1) / pageSize)
    }

    var body: some View {
        Group {
            if embedded {
                hubContent
                    .navigationTitle(navigationTitleText)
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                NavigationStack {
                    hubContent
                        .navigationTitle(navigationTitleText)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    private var hubContent: some View {
        VStack(spacing: 0) {
            Picker("Режим", selection: $track) {
                ForEach(PhrasalTrack.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .onChange(of: track) { _, t in
                TutorBankStore.setMode(t.bankMode)
                reloadPool(resetPage: true)
            }

            Text(track == .onsite
                 ? "Onsite phrasal · Duolingo: слева EN, справа RU"
                 : "Regular phrasal · та же игра, бытовой банк")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            // Sub-menu: verb group
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PhrasalRoundKind.allCases) { kind in
                        Button {
                            roundKind = kind
                            reloadPool(resetPage: true)
                        } label: {
                            Text(kind.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    roundKind == kind
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.secondary.opacity(0.12),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            // Sub-menu: pages for current verb (get · стр. 1/2/3)
            if pageCount > 1 || !pool.isEmpty {
                HStack(spacing: 8) {
                    Button {
                        guard pageIndex > 0 else { return }
                        pageIndex -= 1
                        applyPage()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .frame(width: 32, height: 32)
                    }
                    .disabled(pageIndex <= 0)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(0..<pageCount, id: \.self) { i in
                                Button {
                                    pageIndex = i
                                    applyPage()
                                } label: {
                                    Text(pageChipTitle(i))
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            pageIndex == i
                                            ? Color.accentColor.opacity(0.25)
                                            : Color.secondary.opacity(0.10),
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button {
                        guard pageIndex + 1 < pageCount else { return }
                        pageIndex += 1
                        applyPage()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .frame(width: 32, height: 32)
                    }
                    .disabled(pageIndex + 1 >= pageCount)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                Text("\(roundKind.title) · стр. \(pageIndex + 1)/\(pageCount) · \(seedPhrasals.count) из \(pool.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            TutorPairsView(mode: .phrasal, seedPhrasals: seedPhrasals)
                .id(seedPhrasals.map(\.en).joined(separator: "|"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaPadding(.bottom, 4)
        .onAppear {
            TutorBankStore.setMode(track.bankMode)
            if pool.isEmpty { reloadPool(resetPage: true) }
        }
    }

    private func pageChipTitle(_ i: Int) -> String {
        if roundKind == .mixed {
            return "стр. \(i + 1)"
        }
        return "\(roundKind.title) \(i + 1)"
    }

    private func matches(_ entry: PhrasalEntry, root: String) -> Bool {
        let en = entry.en.lowercased()
        let tokens = en.split(separator: " ").map(String.init)
        let entryRoot = entry.root.lowercased()
        if root == "over" {
            // Particle family: root tagged "over" or last word is "over"
            if entryRoot == "over" { return true }
            if let last = tokens.last, last == "over" { return true }
            return false
        }
        if entryRoot == root { return true }
        if let first = tokens.first, first == root { return true }
        return false
    }

    private func reloadPool(resetPage: Bool) {
        TutorBankStore.ensureLoaded()
        let all = TutorBankStore.phrasals
        let next: [PhrasalEntry]
        if let root = roundKind.rootFilter {
            var filtered = all.filter { matches($0, root: root) }
            // Prefer tier-1, keep stable unique by EN
            var seen = Set<String>()
            filtered = filtered.filter { p in
                let k = p.en.lowercased()
                guard !seen.contains(k) else { return false }
                seen.insert(k)
                return true
            }
            filtered.sort { $0.en.lowercased() < $1.en.lowercased() }
            // Cap at 15 for 3×5 pages (most common set already in bank)
            next = Array(filtered.prefix(15))
        } else {
            // Mixed: 15 shuffled → 3 pages × 5
            next = Array(all.shuffled().prefix(15))
        }
        pool = next
        if resetPage { pageIndex = 0 }
        pageIndex = min(pageIndex, max(0, pageCount - 1))
        applyPage()
    }

    private func applyPage() {
        let start = pageIndex * pageSize
        guard start < pool.count else {
            seedPhrasals = []
            return
        }
        seedPhrasals = Array(pool[start..<min(start + pageSize, pool.count)])
    }
}
