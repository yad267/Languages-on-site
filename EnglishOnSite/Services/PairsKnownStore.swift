import Foundation

/// Persists “Знаю” / know-it IDs for TutorPairs matching rounds (phrasal + opposites).
/// Backed by SwiftData + private CloudKit via CloudUserDataStore (UserDefaults kept as local cache).
enum PairsKnownStore {
    private static let phrasalKey = "eos.pairs.known.phrasal"
    private static let oppositesKey = "eos.pairs.known.opposites"

    static func isKnown(pairId: String, mode: TutorPairsMode) -> Bool {
        let key = normalize(pairId)
        guard !key.isEmpty else { return false }
        return load(mode).contains(key)
    }

    static func markKnown(pairId: String, mode: TutorPairsMode) {
        let key = normalize(pairId)
        guard !key.isEmpty else { return }
        var set = load(mode)
        set.insert(key)
        save(set, mode: mode)
        Task { @MainActor in
            CloudUserDataStore.addMark(namespace: cloudNS(mode), value: key)
        }
    }

    static func filterPhrasals(_ items: [PhrasalEntry]) -> [PhrasalEntry] {
        let known = load(.phrasal)
        return items.filter { !known.contains(normalize($0.en)) }
    }

    static func filterOpposites(_ items: [OppositeEntry]) -> [OppositeEntry] {
        let known = load(.opposites)
        return items.filter { !known.contains(normalize($0.id)) }
    }

    /// Pull CloudKit / SwiftData marks into UserDefaults cache (call after CloudUserDataStore.configure).
    @MainActor
    static func refreshFromCloud() {
        for mode in [TutorPairsMode.phrasal, .opposites] {
            let cloud = CloudUserDataStore.markValues(namespace: cloudNS(mode))
            if !cloud.isEmpty {
                UserDefaults.standard.set(Array(cloud).sorted(), forKey: defaultsKey(mode))
            }
        }
    }

    // MARK: - Storage

    private static func load(_ mode: TutorPairsMode) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey(mode)) ?? [])
    }

    private static func save(_ set: Set<String>, mode: TutorPairsMode) {
        UserDefaults.standard.set(Array(set).sorted(), forKey: defaultsKey(mode))
    }

    private static func defaultsKey(_ mode: TutorPairsMode) -> String {
        switch mode {
        case .phrasal: return phrasalKey
        case .opposites: return oppositesKey
        }
    }

    private static func cloudNS(_ mode: TutorPairsMode) -> String {
        switch mode {
        case .phrasal: return CloudUserDataStore.pairsPhrasalNS
        case .opposites: return CloudUserDataStore.pairsOppositesNS
        }
    }

    private static func normalize(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
