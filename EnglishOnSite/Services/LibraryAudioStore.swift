import Foundation

/// B17b: permanent EN audio files for Мои фразы (not only EL disk-cache lookup).
enum LibraryAudioStore {
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MyPhrasesAudio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func fileURL(fileName: String) -> URL {
        directory().appendingPathComponent(fileName)
    }

    static func hasFile(_ fileName: String?) -> Bool {
        guard let fileName, !fileName.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: fileURL(fileName: fileName).path)
    }

    /// Copy from ElevenLabs cache URL into a stable per-item file.
    @discardableResult
    static func bindFromCacheURL(_ cacheURL: URL, preferredName: String? = nil) -> String? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
        let name = preferredName ?? "\(UUID().uuidString).mp3"
        let dest = fileURL(fileName: name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: cacheURL, to: dest)
            return name
        } catch {
            return nil
        }
    }
}
