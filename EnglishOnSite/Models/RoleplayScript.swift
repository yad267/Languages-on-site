import Foundation

struct RoleplayScript: Codable, Identifiable, Hashable {
    let id: String
    var titleRu: String
    var sceneRu: String
    var roles: [RoleplayRole]
    var lines: [RoleplayLine]
    var sourceRaw: String?
    var createdAt: Date

    var roleNames: [String] { roles.map(\.name) }
}

struct RoleplayRole: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    /// "a" | "b" — maps to ElevenLabs voice
    let slot: String

    var voiceId: String {
        slot == "b" ? ElevenLabsConfig.voiceRoleB : ElevenLabsConfig.voiceRoleA
    }
}

struct RoleplayLine: Codable, Identifiable, Hashable {
    var id: String { "\(index)|\(role)|\(en)" }
    let index: Int
    let role: String
    let en: String
    let ru: String
    let tipRu: String?
}

enum RoleplayParseError: LocalizedError {
    case empty
    case tooShort
    case noLines
    case gemini(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "Опиши диалог своими словами или вставь Name:"
        case .tooShort: return "Слишком короткий текст — добавь тему (tray, clamp…)"
        case .noLines: return "Не нашёл реплики — опиши своими словами или проверь Name:"
        case .gemini(let m): return m
        }
    }
}
