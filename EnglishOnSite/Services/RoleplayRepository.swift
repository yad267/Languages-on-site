import Foundation
import Observation

@Observable
@MainActor
final class RoleplayRepository {
    static let shared = RoleplayRepository()

    private(set) var scripts: [RoleplayScript] = []

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Roleplays", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    init() { reload() }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let jsons = urls.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        scripts = jsons.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let s = try? dec.decode(RoleplayScript.self, from: data),
                  !s.lines.isEmpty else { return nil }
            return s
        }
    }

    func save(_ script: RoleplayScript) throws {
        let url = directory.appendingPathComponent("\(script.id).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(script).write(to: url, options: .atomic)
        reload()
    }

    func delete(id: String) throws {
        let url = directory.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        reload()
    }
}
