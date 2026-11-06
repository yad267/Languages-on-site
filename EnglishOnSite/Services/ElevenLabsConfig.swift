import Foundation

/// ElevenLabs model IDs (Settings picker). Factory default = eleven_v4.
enum ElevenLabsModelID: String, CaseIterable, Identifiable, Codable {
    case v4 = "eleven_v4"
    case multilingualV2 = "eleven_multilingual_v2"
    case turboV25 = "eleven_turbo_v2_5"

    var id: String { rawValue }

    var titleRu: String {
        switch self {
        case .v4: return "eleven_v4"
        case .multilingualV2: return "multilingual_v2"
        case .turboV25: return "turbo_v2_5"
        }
    }
}

/// Per-request voice_settings + model (factory-style).
struct ElevenLabsVoiceParams: Equatable {
    var model: ElevenLabsModelID
    var stability: Double
    var similarityBoost: Double
    var style: Double
    var useSpeakerBoost: Bool

    /// Compact fingerprint for disk cache key (rounded to avoid float noise).
    var cacheFingerprint: String {
        let s = String(format: "%.2f", stability)
        let sim = String(format: "%.2f", similarityBoost)
        let st = String(format: "%.2f", style)
        let boost = useSpeakerBoost ? "1" : "0"
        return "\(model.rawValue)|s\(s)|sim\(sim)|st\(st)|b\(boost)"
    }

    var voiceSettingsJSON: [String: Any] {
        [
            "stability": stability,
            "similarity_boost": similarityBoost,
            "style": style,
            "use_speaker_boost": useSpeakerBoost,
        ]
    }
}

/// Single place for voice IDs + factory defaults (RU clone + EN on eleven_v4).
enum ElevenLabsConfig {
    static let voiceEN = "WrjxnKxK0m1uiaH0uteU"
    static let voiceRU = "b2LgEdbhF1USG5rOxP3Q"

    /// Lesson dialogue: монтажник / worker (EN). Same as current site EN.
    static let voiceIdEnWorker = voiceEN

    /// Lesson dialogue: бригадир / supervisor (EN).
    /// TODO: replace with a second ElevenLabs EN voice ID when available.
    /// Until then equals worker so TTS still works; override in Settings → «ID голоса бригадира».
    static let voiceIdEnSupervisorPlaceholder = voiceEN

    /// Roleplay: two distinct site voices.
    static let voiceRoleA = voiceEN
    static let voiceRoleB = voiceRU

    static let apiRoot = "https://api.elevenlabs.io/v1/text-to-speech"

    /// NodeForge 1.3 — disk cache caps (LRU by mtime).
    static let cacheMaxFiles = 500
    static let cacheMaxBytes = 200 * 1024 * 1024

    /// Factory default model (both EN + RU).
    static let defaultModel: ElevenLabsModelID = .v4

    /// Bump to force one-time UserDefaults → factory v4 + cache clear.
    static let factoryEpoch = 2

    /// Factory voice_settings (same for EN + RU unless user overrides in Settings).
    static let factoryStability = 0.70
    static let factorySimilarity = 0.85
    static let factoryStyle = 0.10

    static let defaultRU = ElevenLabsVoiceParams(
        model: defaultModel,
        stability: factoryStability,
        similarityBoost: factorySimilarity,
        style: factoryStyle,
        useSpeakerBoost: true
    )

    static let defaultEN = ElevenLabsVoiceParams(
        model: defaultModel,
        stability: factoryStability,
        similarityBoost: factorySimilarity,
        style: factoryStyle,
        useSpeakerBoost: true
    )

    /// EN playback rate from Settings (local AVAudioPlayer rate).
    static func enSpeed(for english: EnglishSpeechSpeed) -> Double {
        switch english {
        case .slow: return 0.82
        case .normal: return 0.92
        case .fast: return 1.05
        }
    }

    static func ruSpeed() -> Double { 1.0 }
}
