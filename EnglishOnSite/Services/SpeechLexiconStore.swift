import Foundation
import Observation

/// Personal speech lexicon: **n8n = source of truth**, Documents = offline cache.
/// Pull on launch; push on every merge. Merge by `id` never drops old terms.
@MainActor
@Observable
final class SpeechLexiconStore {
    static let shared = SpeechLexiconStore()

    /// Default production webhook (workflow «EOS — Speech Lexicon»).
    static let defaultWebhookURL = "https://n8n.yad26ai.uk/webhook/eos-speech-lexicon"
    static let defaultUserKey = "dima"

    private(set) var entries: [LearnerSpeechTermEntry] = []
    private(set) var lastToast: String = ""
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String = ""

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("SpeechLexicon", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("lexicon.json")
    }

    private init() {
        entries = loadCache()
    }

    var spokenTerms: [String] { entries.map(\.spoken) }

    // MARK: - Boot / pull

    /// Pull from n8n and merge into local cache + learner profile.
    func pullFromN8N(userKey: String = defaultUserKey, webhookURL: String? = nil) async {
        lastError = ""
        do {
            let remote = try await post(action: "get", entries: [], userKey: userKey, webhookURL: webhookURL)
            applyMerged(remote, toast: false)
            lastSyncedAt = Date()
        } catch {
            lastError = error.localizedDescription
            print("[speech-lex] pull fail \(error.localizedDescription.prefix(80))")
        }
    }

    // MARK: - Ingest

    /// Harvest new slang from ASR/text, merge locally, push to n8n. Returns newly added spoken forms.
    @discardableResult
    func ingest(
        text: String,
        source: SpeechTermSource,
        knownProfileTerms: [String] = [],
        userKey: String = defaultUserKey,
        webhookURL: String? = nil
    ) async -> [String] {
        let harvested = LearnerSpeechLexicon.harvestEntries(
            from: text,
            knownSpoken: Set((spokenTerms + knownProfileTerms).map { $0.lowercased() }),
            source: source
        )
        guard !harvested.isEmpty else { return [] }

        let before = Set(entries.map { $0.id.lowercased() })
        let mergedLocal = LearnerSpeechTermEntry.mergeAll([entries, harvested])
        entries = mergedLocal
        saveCache(mergedLocal)
        syncIntoProfile(mergedLocal)

        let newly = mergedLocal.filter { !before.contains($0.id.lowercased()) }.map(\.spoken)
        if !newly.isEmpty {
            lastToast = newly.count == 1
                ? "В словарь: \(newly[0])"
                : "В словарь: " + newly.prefix(4).joined(separator: ", ")
                    + (newly.count > 4 ? " +\(newly.count - 4)" : "")
        }

        // Push merge to n8n (source of truth). Keep local even if network fails.
        do {
            let remote = try await post(
                action: "merge",
                entries: mergedLocal,
                userKey: userKey,
                webhookURL: webhookURL
            )
            applyMerged(remote, toast: false)
            lastSyncedAt = Date()
            lastError = ""
        } catch {
            lastError = error.localizedDescription
            print("[speech-lex] push fail \(error.localizedDescription.prefix(80))")
        }
        return newly
    }

    func clearToast() { lastToast = "" }

    // MARK: - Private

    private func applyMerged(_ remote: [LearnerSpeechTermEntry], toast: Bool) {
        let merged = LearnerSpeechTermEntry.mergeAll([entries, remote])
        let before = Set(entries.map(\.id))
        entries = merged
        saveCache(merged)
        syncIntoProfile(merged)
        if toast {
            let newly = merged.filter { !before.contains($0.id) }.map(\.spoken)
            if !newly.isEmpty {
                lastToast = "Словарь с сервера: " + newly.prefix(3).joined(separator: ", ")
            }
        }
    }

    private func syncIntoProfile(_ list: [LearnerSpeechTermEntry]) {
        var profile = LearnerProfileStore.shared.profile
        let spoken = list.map(\.spoken)
        // Merge strings without wiping older profile-only terms.
        var seen = Set(spoken.map { $0.lowercased() })
        var terms = spoken
        for t in profile.speechTerms {
            let form = LearnerSpeechLexicon.cyrillicForm(t)
            if seen.insert(form.lowercased()).inserted { terms.append(form) }
        }
        let entriesMerged = LearnerSpeechTermEntry.mergeAll([
            list,
            profile.speechTermEntries,
            terms.map { LearnerSpeechTermEntry(spoken: $0, source: .manual) },
        ])
        if profile.speechTerms == terms, profile.speechTermEntries == entriesMerged { return }
        profile.speechTerms = entriesMerged.map(\.spoken)
        profile.speechTermEntries = entriesMerged
        LearnerProfileStore.shared.save(profile, applyLearningModeTo: nil)
    }

    private struct DiskPack: Codable {
        var entries: [LearnerSpeechTermEntry]
        var updatedAt: Date?
    }

    private func loadCache() -> [LearnerSpeechTermEntry] {
        guard let data = try? Data(contentsOf: cacheURL),
              let pack = try? JSONDecoder().decode(DiskPack.self, from: data) else { return [] }
        return pack.entries
    }

    private func saveCache(_ list: [LearnerSpeechTermEntry]) {
        let pack = DiskPack(entries: list, updatedAt: Date())
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(pack) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private struct APIResponse: Decodable {
        var ok: Bool?
        var entries: [LearnerSpeechTermEntry]?
        var error: String?
    }

    private func post(
        action: String,
        entries: [LearnerSpeechTermEntry],
        userKey: String,
        webhookURL: String?
    ) async throws -> [LearnerSpeechTermEntry] {
        let urlString = (webhookURL?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.defaultWebhookURL
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let entriesJSON = try JSONSerialization.jsonObject(with: try enc.encode(entries))
        let body: [String: Any] = [
            "action": action,
            "userKey": userKey,
            "entries": entriesJSON,
        ]
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw URLError(.badServerResponse)
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let parsed = try? dec.decode(APIResponse.self, from: data) {
            if parsed.ok == false {
                throw URLError(.cannotParseResponse)
            }
            return parsed.entries ?? []
        }
        // Fallback without date strategy
        let parsed = try JSONDecoder().decode(APIResponse.self, from: data)
        return parsed.entries ?? []
    }
}
