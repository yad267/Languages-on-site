import Foundation
import Observation

enum EnglishSpeechSpeed: String, CaseIterable, Identifiable, Codable {
    case slow, normal, fast

    var id: String { rawValue }

    var titleRu: String {
        switch self {
        case .slow: return "Медленно"
        case .normal: return "Нормально"
        case .fast: return "Быстро"
        }
    }

    var rate: Float {
        switch self {
        case .slow: return 0.42
        case .normal: return 0.48
        case .fast: return 0.54
        }
    }
}

enum RememberDuration: Int, CaseIterable, Identifiable, Codable {
    case s30 = 30
    case s45 = 45
    case s60 = 60

    var id: Int { rawValue }
    var titleRu: String { "\(rawValue) сек" }
}

/// Max recording length (user stops earlier with «Готово»).
enum TranslateDuration: Int, CaseIterable, Identifiable, Codable {
    case s30 = 30
    case s45 = 45
    case s60 = 60

    var id: Int { rawValue }
    var titleRu: String { "до \(rawValue) сек" }
}

enum RememberLocale: String, CaseIterable, Identifiable, Codable {
    case enIE = "en-IE"
    case enGB = "en-GB"

    var id: String { rawValue }
    var titleRu: String { rawValue }
}

@Observable
final class AppSettings {
    private var isBootstrapping = true

    private enum Keys {
        static let englishSpeed = "englishSpeed"
        static let speechRate = "speechRate"
        static let voiceCommands = "voiceCommands"
        static let showTips = "showTips"
        static let rememberDuration = "rememberDuration"
        static let translateDuration = "translateDuration"
        static let rememberLocale = "rememberLocale"
        static let useGemini = "useGemini"
        static let useElevenLabs = "useElevenLabs"
        static let elModel = "elModel"
        static let elStabilityEN = "elStabilityEN"
        static let elStabilityRU = "elStabilityRU"
        static let elSimilarityEN = "elSimilarityEN"
        static let elSimilarityRU = "elSimilarityRU"
        static let elStyleEN = "elStyleEN"
        static let elStyleRU = "elStyleRU"
        static let elFactoryEpoch = "elFactoryEpoch"
        static let lessonsPackURL = "lessonsPackURL"
        static let voiceIdEnSupervisor = "voiceIdEnSupervisor"
        static let eosSyncWebhookURL = "eosSyncWebhookURL"
    }

    var englishSpeed: EnglishSpeechSpeed {
        didSet { UserDefaults.standard.set(englishSpeed.rawValue, forKey: Keys.englishSpeed) }
    }

    var showTips: Bool {
        didSet { UserDefaults.standard.set(showTips, forKey: Keys.showTips) }
    }

    var voiceCommands: VoiceCommands {
        didSet {
            if let data = try? JSONEncoder().encode(voiceCommands) {
                UserDefaults.standard.set(data, forKey: Keys.voiceCommands)
            }
        }
    }

    var rememberDuration: RememberDuration {
        didSet { UserDefaults.standard.set(rememberDuration.rawValue, forKey: Keys.rememberDuration) }
    }

    var translateDuration: TranslateDuration {
        didSet { UserDefaults.standard.set(translateDuration.rawValue, forKey: Keys.translateDuration) }
    }

    var rememberLocale: RememberLocale {
        didSet { UserDefaults.standard.set(rememberLocale.rawValue, forKey: Keys.rememberLocale) }
    }

    /// Toggle only — key lives in Keychain.
    var useGemini: Bool {
        didSet { UserDefaults.standard.set(useGemini, forKey: Keys.useGemini) }
    }

    var useElevenLabs: Bool {
        didSet { UserDefaults.standard.set(useElevenLabs, forKey: Keys.useElevenLabs) }
    }

    /// Shared model for EN + RU TTS requests.
    var elModel: ElevenLabsModelID {
        didSet {
            UserDefaults.standard.set(elModel.rawValue, forKey: Keys.elModel)
            if !isBootstrapping, oldValue != elModel {
                let n = ElevenLabsAudioCache.clearAll()
                print("[el] model changed →\(elModel.rawValue) cache cleared files=\(n)")
            }
        }
    }

    var elStabilityEN: Double {
        didSet { UserDefaults.standard.set(elStabilityEN, forKey: Keys.elStabilityEN) }
    }

    var elStabilityRU: Double {
        didSet { UserDefaults.standard.set(elStabilityRU, forKey: Keys.elStabilityRU) }
    }

    var elSimilarityEN: Double {
        didSet { UserDefaults.standard.set(elSimilarityEN, forKey: Keys.elSimilarityEN) }
    }

    var elSimilarityRU: Double {
        didSet { UserDefaults.standard.set(elSimilarityRU, forKey: Keys.elSimilarityRU) }
    }

    var elStyleEN: Double {
        didSet { UserDefaults.standard.set(elStyleEN, forKey: Keys.elStyleEN) }
    }

    var elStyleRU: Double {
        didSet { UserDefaults.standard.set(elStyleRU, forKey: Keys.elStyleRU) }
    }

    func elVoiceParams(for lang: SiteVoiceLang) -> ElevenLabsVoiceParams {
        switch lang {
        case .en:
            return ElevenLabsVoiceParams(
                model: elModel,
                stability: elStabilityEN,
                similarityBoost: elSimilarityEN,
                style: elStyleEN,
                useSpeakerBoost: true
            )
        case .ru:
            return ElevenLabsVoiceParams(
                model: elModel,
                stability: elStabilityRU,
                similarityBoost: elSimilarityRU,
                style: elStyleRU,
                useSpeakerBoost: true
            )
        }
    }

    /// Google Drive direct download URL for lessons_pack.json
    var lessonsPackURL: String {
        didSet { UserDefaults.standard.set(lessonsPackURL, forKey: Keys.lessonsPackURL) }
    }

    /// Second EN voice for бригадир / supervisor in lesson dialogue. Empty → placeholder (= worker for now).
    var voiceIdEnSupervisor: String {
        didSet { UserDefaults.standard.set(voiceIdEnSupervisor, forKey: Keys.voiceIdEnSupervisor) }
    }

    /// Optional n8n/Drive sync webhook. Empty = sync off (not an error).
    var eosSyncWebhookURL: String {
        didSet { UserDefaults.standard.set(eosSyncWebhookURL, forKey: Keys.eosSyncWebhookURL) }
    }

    /// Resolved supervisor EN voice id (Settings override or factory placeholder).
    var resolvedVoiceIdEnSupervisor: String {
        let trimmed = voiceIdEnSupervisor.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return ElevenLabsConfig.voiceIdEnSupervisorPlaceholder
    }

    func resetELVoiceDefaults() {
        let prev = elModel
        elModel = ElevenLabsConfig.defaultModel
        elStabilityEN = ElevenLabsConfig.defaultEN.stability
        elSimilarityEN = ElevenLabsConfig.defaultEN.similarityBoost
        elStyleEN = ElevenLabsConfig.defaultEN.style
        elStabilityRU = ElevenLabsConfig.defaultRU.stability
        elSimilarityRU = ElevenLabsConfig.defaultRU.similarityBoost
        elStyleRU = ElevenLabsConfig.defaultRU.style
        // If model unchanged, still wipe stale multilingual mp3.
        if prev == elModel {
            _ = ElevenLabsAudioCache.clearAll()
        }
        UserDefaults.standard.set(ElevenLabsConfig.factoryEpoch, forKey: Keys.elFactoryEpoch)
    }

    /// One-shot: nail factory eleven_v4 + voice_settings; clear old multilingual cache.
    func migrateELFactoryIfNeeded() {
        let epoch = UserDefaults.standard.integer(forKey: Keys.elFactoryEpoch)
        guard epoch < ElevenLabsConfig.factoryEpoch else { return }
        print("[el] migrate factory epoch \(epoch)→\(ElevenLabsConfig.factoryEpoch)")
        resetELVoiceDefaults()
    }

    /// Bound in Settings; writes to Keychain on change.
    var geminiAPIKeyDraft: String {
        didSet {
            guard !isBootstrapping else { return }
            let trimmed = Self.sanitizeKey(geminiAPIKeyDraft)
            if trimmed != geminiAPIKeyDraft {
                geminiAPIKeyDraft = trimmed
                return
            }
            KeychainStore.saveGeminiAPIKey(trimmed)
            if trimmed.isEmpty {
                useGemini = false
            } else if !useGemini {
                useGemini = true
            }
        }
    }

    var elevenLabsAPIKeyDraft: String {
        didSet {
            guard !isBootstrapping else { return }
            let trimmed = Self.sanitizeKey(elevenLabsAPIKeyDraft)
            if trimmed != elevenLabsAPIKeyDraft {
                elevenLabsAPIKeyDraft = trimmed
                return
            }
            KeychainStore.saveElevenLabsAPIKey(trimmed)
            if trimmed.isEmpty {
                useElevenLabs = false
            } else if !useElevenLabs {
                useElevenLabs = true
            }
        }
    }

    private static func sanitizeKey(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (key.hasPrefix("\"") && key.hasSuffix("\"")) || (key.hasPrefix("'") && key.hasSuffix("'")) {
            key = String(key.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if key.lowercased().hasPrefix("bearer ") {
            key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return key
    }

    var hasGeminiKey: Bool {
        !geminiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || KeychainStore.hasGeminiAPIKey()
    }

    var geminiEnabledAndReady: Bool {
        useGemini && hasGeminiKey
    }

    var hasElevenLabsKey: Bool {
        !elevenLabsAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || KeychainStore.hasElevenLabsAPIKey()
    }

    var elevenLabsEnabledAndReady: Bool {
        useElevenLabs && hasElevenLabsKey
    }

    var englishRate: Float { englishSpeed.rate }
    var russianRate: Float { 0.50 }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Keys.englishSpeed),
           let speed = EnglishSpeechSpeed(rawValue: raw) {
            englishSpeed = speed
        } else if let legacy = UserDefaults.standard.object(forKey: Keys.speechRate) as? Float {
            if legacy <= 0.44 { englishSpeed = .slow }
            else if legacy >= 0.52 { englishSpeed = .fast }
            else { englishSpeed = .normal }
        } else {
            englishSpeed = .slow
        }

        if UserDefaults.standard.object(forKey: Keys.showTips) != nil {
            showTips = UserDefaults.standard.bool(forKey: Keys.showTips)
        } else {
            showTips = true
        }

        if let data = UserDefaults.standard.data(forKey: Keys.voiceCommands),
           let decoded = try? JSONDecoder().decode(VoiceCommands.self, from: data) {
            voiceCommands = decoded
        } else {
            voiceCommands = .default
        }

        let rem = UserDefaults.standard.object(forKey: Keys.rememberDuration) as? Int
        rememberDuration = RememberDuration(rawValue: rem ?? 45) ?? .s45

        let tr = UserDefaults.standard.object(forKey: Keys.translateDuration) as? Int
        // Migrate old 4/6/8 fixed modes → max-length 30/45/60
        if let tr, let modern = TranslateDuration(rawValue: tr) {
            translateDuration = modern
        } else if let tr, tr <= 8 {
            translateDuration = .s30
        } else {
            translateDuration = .s45
        }

        if let loc = UserDefaults.standard.string(forKey: Keys.rememberLocale),
           let remembered = RememberLocale(rawValue: loc) {
            rememberLocale = remembered
        } else {
            rememberLocale = .enIE
        }

        // Load toggle before key draft to avoid didSet forcing ON on launch.
        if UserDefaults.standard.object(forKey: Keys.useGemini) != nil {
            useGemini = UserDefaults.standard.bool(forKey: Keys.useGemini)
        } else {
            useGemini = false
        }

        if UserDefaults.standard.object(forKey: Keys.useElevenLabs) != nil {
            useElevenLabs = UserDefaults.standard.bool(forKey: Keys.useElevenLabs)
        } else {
            useElevenLabs = false
        }

        if let raw = UserDefaults.standard.string(forKey: Keys.elModel),
           let model = ElevenLabsModelID(rawValue: raw) {
            elModel = model
        } else {
            elModel = ElevenLabsConfig.defaultModel
        }

        func loadDouble(_ key: String, fallback: Double) -> Double {
            if UserDefaults.standard.object(forKey: key) != nil {
                return UserDefaults.standard.double(forKey: key)
            }
            return fallback
        }
        elStabilityEN = loadDouble(Keys.elStabilityEN, fallback: ElevenLabsConfig.defaultEN.stability)
        elSimilarityEN = loadDouble(Keys.elSimilarityEN, fallback: ElevenLabsConfig.defaultEN.similarityBoost)
        elStyleEN = loadDouble(Keys.elStyleEN, fallback: ElevenLabsConfig.defaultEN.style)
        elStabilityRU = loadDouble(Keys.elStabilityRU, fallback: ElevenLabsConfig.defaultRU.stability)
        elSimilarityRU = loadDouble(Keys.elSimilarityRU, fallback: ElevenLabsConfig.defaultRU.similarityBoost)
        elStyleRU = loadDouble(Keys.elStyleRU, fallback: ElevenLabsConfig.defaultRU.style)

        lessonsPackURL = UserDefaults.standard.string(forKey: Keys.lessonsPackURL) ?? ""
        voiceIdEnSupervisor = UserDefaults.standard.string(forKey: Keys.voiceIdEnSupervisor) ?? ""
        eosSyncWebhookURL = UserDefaults.standard.string(forKey: Keys.eosSyncWebhookURL) ?? ""

        let storedKey = KeychainStore.loadGeminiAPIKey()
        geminiAPIKeyDraft = storedKey
        if UserDefaults.standard.object(forKey: Keys.useGemini) == nil {
            useGemini = !storedKey.isEmpty
        }

        let elKey = KeychainStore.loadElevenLabsAPIKey()
        elevenLabsAPIKeyDraft = elKey
        if UserDefaults.standard.object(forKey: Keys.useElevenLabs) == nil {
            useElevenLabs = !elKey.isEmpty
        }
        isBootstrapping = false
        migrateELFactoryIfNeeded()
    }

    /// Call on app appear: Secrets.local → Keychain (empty or Secrets ≠ Keychain).
    func seedFromLocalSecretsIfNeeded() {
        _ = AppSecrets.seedKeychainIfNeeded(into: self)
        geminiAPIKeyDraft = KeychainStore.loadGeminiAPIKey()
        elevenLabsAPIKeyDraft = KeychainStore.loadElevenLabsAPIKey()
    }

    /// Settings button: force both keys from Secrets.local into Keychain.
    @discardableResult
    func rereadSecretsFromDisk() -> String {
        let msg = AppSecrets.rereadSecretsIntoKeychain(into: self)
        geminiAPIKeyDraft = KeychainStore.loadGeminiAPIKey()
        elevenLabsAPIKeyDraft = KeychainStore.loadElevenLabsAPIKey()
        return msg
    }

    func clearGeminiKey() {
        geminiAPIKeyDraft = ""
        KeychainStore.saveGeminiAPIKey("")
        useGemini = false
    }

    func clearElevenLabsKey() {
        elevenLabsAPIKeyDraft = ""
        KeychainStore.saveElevenLabsAPIKey("")
        useElevenLabs = false
    }
}
