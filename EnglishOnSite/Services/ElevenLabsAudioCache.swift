import CryptoKit
import Foundation

/// NodeForge 1.3 — stable on-disk MP3 cache for ElevenLabs (no network).
enum ElevenLabsAudioCache {
    /// Normalize for cache key only (API still gets trimmed original text).
    static func normalizeForKey(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Key includes model + voice_settings fingerprint so param changes never hit stale mp3.
    static func cacheKey(
        text: String,
        voice: String,
        params: ElevenLabsVoiceParams
    ) -> String {
        let normalized = normalizeForKey(text)
        let raw = "\(params.cacheFingerprint)|\(voice)|\(normalized)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func directory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ElevenLabsTTS", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func fileURL(
        text: String,
        voice: String,
        params: ElevenLabsVoiceParams
    ) -> URL {
        directory().appendingPathComponent(
            "\(cacheKey(text: text, voice: voice, params: params)).mp3"
        )
    }

    static func hasFile(
        text: String,
        voice: String,
        params: ElevenLabsVoiceParams
    ) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(text: text, voice: voice, params: params).path)
    }

    /// Bump mtime so LRU keeps hot phrases.
    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    /// Delete all cached mp3 (model change / Settings «Очистить кэш голоса»).
    @discardableResult
    static func clearAll() -> Int {
        let fm = FileManager.default
        let dir = directory()
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var removed = 0
        for url in urls where url.pathExtension.lowercased() == "mp3" {
            try? fm.removeItem(at: url)
            removed += 1
        }
        print("[el] cache clearAll removed=\(removed)")
        return removed
    }

    /// Drop oldest mp3 until under max files / max bytes.
    @discardableResult
    static func pruneIfNeeded(
        maxFiles: Int = ElevenLabsConfig.cacheMaxFiles,
        maxBytes: Int = ElevenLabsConfig.cacheMaxBytes
    ) -> Int {
        let fm = FileManager.default
        let dir = directory()
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var entries: [(url: URL, date: Date, size: Int)] = urls.compactMap { url in
            guard url.pathExtension.lowercased() == "mp3" else { return nil }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = vals?.contentModificationDate ?? .distantPast
            let size = vals?.fileSize ?? 0
            return (url, date, size)
        }
        entries.sort { $0.date < $1.date } // oldest first

        var total = entries.reduce(0) { $0 + $1.size }
        var removed = 0

        while entries.count > maxFiles || total > maxBytes {
            guard let victim = entries.first else { break }
            try? fm.removeItem(at: victim.url)
            total -= victim.size
            entries.removeFirst()
            removed += 1
        }
        if removed > 0 {
            print("[el] cache prune removed=\(removed) left=\(entries.count) bytes=\(total)")
        }
        return removed
    }

    /// DEBUG / report: empty = OK. Also writes+reads a probe file (no HTTP).
    static func selfCheckFailures() -> [String] {
        var fails: [String] = []
        var p = ElevenLabsConfig.defaultEN
        let a = cacheKey(text: "  Pass me the drill, please. ", voice: "v1", params: p)
        let b = cacheKey(text: "pass me the drill, please.", voice: "v1", params: p)
        if a != b { fails.append("normalize key mismatch") }
        let c = cacheKey(text: "pass me the drill, please.", voice: "v2", params: p)
        if a == c { fails.append("voice must change key") }

        var p2 = p
        p2.stability = 0.90
        let d = cacheKey(text: "pass me the drill, please.", voice: "v1", params: p2)
        if a == d { fails.append("stability must change key") }

        var p3 = p
        p3.model = .turboV25
        let e = cacheKey(text: "pass me the drill, please.", voice: "v1", params: p3)
        if a == e { fails.append("model must change key") }

        let probeText = "__eos_cache_probe__"
        let probeVoice = ElevenLabsConfig.voiceEN
        let url = fileURL(text: probeText, voice: probeVoice, params: p)
        let payload = Data([0xFF, 0xFB, 0x90, 0x00])
        do {
            try payload.write(to: url, options: .atomic)
            touch(url)
            if !hasFile(text: probeText, voice: probeVoice, params: p) {
                fails.append("probe write not visible as hit")
            }
            let url2 = fileURL(text: "  \(probeText)  ", voice: probeVoice, params: p)
            if url.path != url2.path { fails.append("probe key unstable") }
            // Different stability → different path (must not hit old probe)
            if hasFile(text: probeText, voice: probeVoice, params: p2) {
                fails.append("stability change still hits old cache")
            }
            try? FileManager.default.removeItem(at: url)
        } catch {
            fails.append("probe write failed")
        }

        _ = pruneIfNeeded()
        return fails
    }
}
