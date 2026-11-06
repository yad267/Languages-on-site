import AVFoundation
import Foundation

enum SiteVoiceLang {
    case en, ru

    var voiceId: String {
        switch self {
        case .en: return ElevenLabsConfig.voiceEN
        case .ru: return ElevenLabsConfig.voiceRU
        }
    }

    var shortLabel: String { self == .en ? "EN" : "RU" }
}

enum ElevenLabsAudioSource: String {
    case cache
    case network
    case system
}

/// ElevenLabs TTS with disk cache + AVSpeech fallback (never log API key).
@MainActor
final class ElevenLabsTTS: NSObject {
    static let shared = ElevenLabsTTS()

    private var player: AVAudioPlayer?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var generation = 0
    private let fallbackSynth = AVSpeechSynthesizer()

    /// True when last utterance used system AVSpeech.
    private(set) var lastUsedSystemVoice = false
    /// Short RU reason for UI, e.g. «EL ошибка: HTTP 401».
    private(set) var lastErrorRU: String = ""
    /// Where last successful EL audio came from (cache vs network); system if fallback.
    private(set) var lastSource: ElevenLabsAudioSource = .system

    /// Visible status for player / tutor: «из кэша» / «сеть/EL» / error / «системный голос».
    var lastStatusRU: String {
        if lastUsedSystemVoice {
            return lastErrorRU.isEmpty ? "системный голос" : lastErrorRU
        }
        switch lastSource {
        case .cache: return "из кэша"
        case .network: return "сеть/EL"
        case .system: return lastErrorRU.isEmpty ? "системный голос" : lastErrorRU
        }
    }

    override init() {
        super.init()
        fallbackSynth.delegate = self
    }

    func stop() {
        generation += 1
        fallbackSynth.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        resumeFinish()
    }

    func pause() {
        player?.pause()
        if fallbackSynth.isSpeaking {
            fallbackSynth.pauseSpeaking(at: .word)
        }
    }

    @discardableResult
    func resumePlayback() -> Bool {
        if let player, !player.isPlaying, player.currentTime > 0 {
            return player.play()
        }
        if fallbackSynth.isPaused {
            return fallbackSynth.continueSpeaking()
        }
        return false
    }

    var isPausedPlayback: Bool {
        if let player, !player.isPlaying, player.currentTime > 0, player.currentTime < player.duration {
            return true
        }
        return fallbackSynth.isPaused
    }

    /// Sync disk-cache probe (Pairs: decide warm-before-remove).
    func isCached(text: String, lang: SiteVoiceLang = .en, settings: AppSettings) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let apiKey = AppSecrets.sanitizeSecret(KeychainStore.loadElevenLabsAPIKey())
        guard settings.useElevenLabs, !apiKey.isEmpty else {
            // System voice is local — treat as "ready".
            return true
        }
        let voiceParams = settings.elVoiceParams(for: lang)
        return ElevenLabsAudioCache.hasFile(
            text: trimmed,
            voice: lang.voiceId,
            params: voiceParams
        )
    }

    /// Download MP3 to disk if missing — no playback (Pairs prefetch).
    func prefetchToDisk(
        text: String,
        lang: SiteVoiceLang = .en,
        settings: AppSettings
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let apiKey = AppSecrets.sanitizeSecret(KeychainStore.loadElevenLabsAPIKey())
        guard settings.useElevenLabs, !apiKey.isEmpty else { return }
        let voiceId = lang.voiceId
        let voiceParams = settings.elVoiceParams(for: lang)
        let cacheURL = ElevenLabsAudioCache.fileURL(
            text: trimmed,
            voice: voiceId,
            params: voiceParams
        )
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            ElevenLabsAudioCache.touch(cacheURL)
            return
        }
        _ = await fetchFromNetwork(
            text: trimmed,
            voiceId: voiceId,
            apiKey: apiKey,
            cacheURL: cacheURL,
            params: voiceParams,
            settings: settings,
            sync: nil
        )
    }

    /// Speaks and returns when done (or cancelled via `stop()`).
    func speak(
        text: String,
        lang: SiteVoiceLang,
        settings: AppSettings,
        sync: EosTTSSyncContext? = nil,
        onPlaybackStarted: (() -> Void)? = nil
    ) async {
        await speak(
            text: text,
            voiceId: lang.voiceId,
            lang: lang,
            settings: settings,
            sync: sync,
            onPlaybackStarted: onPlaybackStarted
        )
    }

    /// Roleplay / tutor / lesson: explicit ElevenLabs `voice_id` with disk cache.
    func speak(
        text: String,
        voiceId: String,
        lang: SiteVoiceLang,
        settings: AppSettings,
        sync: EosTTSSyncContext? = nil,
        onPlaybackStarted: (() -> Void)? = nil
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()
        let gen = generation
        lastUsedSystemVoice = false
        lastErrorRU = ""
        lastSource = .system

        let apiKey = AppSecrets.sanitizeSecret(KeychainStore.loadElevenLabsAPIKey())
        // Presence only — do not gate on sk_ prefix (blocked seed/UI + silent AVSpeech).
        let enabled = settings.useElevenLabs && !apiKey.isEmpty
        let voiceParams = settings.elVoiceParams(for: lang)
        let cacheURL = ElevenLabsAudioCache.fileURL(
            text: trimmed,
            voice: voiceId,
            params: voiceParams
        )
        let cacheExists = FileManager.default.fileExists(atPath: cacheURL.path)

        print("[el] start lang=\(lang.shortLabel) voice=\(voiceId.prefix(6))… enabled=\(enabled) key=\(apiKey.isEmpty ? "no" : "yes") toggle=\(settings.useElevenLabs) model=\(voiceParams.model.rawValue) stab=\(String(format: "%.2f", voiceParams.stability)) cacheExists=\(cacheExists)")

        // Airplane / repeat: play cached mp3 even if network is down (key+toggle still required).
        if enabled, cacheExists {
            lastSource = .cache
            ElevenLabsAudioCache.touch(cacheURL)
            print("[el] cache hit")
            let playbackRate = Float(
                lang == .en
                    ? ElevenLabsConfig.enSpeed(for: settings.englishSpeed)
                    : ElevenLabsConfig.ruSpeed()
            )
            do {
                try await playFile(url: cacheURL, rate: playbackRate, onStarted: onPlaybackStarted)
                print("[el] ok source=cache")
                return
            } catch {
                lastErrorRU = "EL ошибка: воспроизведение"
                print("[el] fail reason=play_cache")
                // Fall through to network / system
            }
        } else if enabled {
            print("[el] cache miss")
        }

        guard enabled else {
            if apiKey.isEmpty {
                lastErrorRU = "EL ошибка: нет ключа"
                print("[el] fail reason=no_key")
            } else {
                lastErrorRU = "EL выкл в Настройках"
                print("[el] fail reason=toggle_off")
            }
            lastUsedSystemVoice = true
            lastSource = .system
            await speakSystem(text: trimmed, lang: lang, settings: settings, onStarted: onPlaybackStarted)
            return
        }

        let playbackRate = Float(
            lang == .en
                ? ElevenLabsConfig.enSpeed(for: settings.englishSpeed)
                : ElevenLabsConfig.ruSpeed()
        )
        await speakNetworkOrFallback(
            text: trimmed,
            voiceId: voiceId,
            lang: lang,
            settings: settings,
            voiceParams: voiceParams,
            generation: gen,
            playbackRate: playbackRate,
            apiKey: apiKey,
            cacheURL: cacheURL,
            sync: sync,
            onPlaybackStarted: onPlaybackStarted
        )
    }

    private func speakNetworkOrFallback(
        text: String,
        voiceId: String,
        lang: SiteVoiceLang,
        settings: AppSettings,
        voiceParams: ElevenLabsVoiceParams,
        generation gen: Int,
        playbackRate: Float,
        apiKey: String,
        cacheURL: URL,
        sync: EosTTSSyncContext?,
        onPlaybackStarted: (() -> Void)?
    ) async {
        switch await fetchFromNetwork(
            text: text,
            voiceId: voiceId,
            apiKey: apiKey,
            cacheURL: cacheURL,
            params: voiceParams,
            settings: settings,
            sync: sync
        ) {
        case .success(let url):
            guard gen == generation else { return }
            lastSource = .network
            do {
                try await playFile(url: url, rate: playbackRate, onStarted: onPlaybackStarted)
                print("[el] ok source=network")
                return
            } catch {
                lastErrorRU = "EL ошибка: воспроизведение"
                print("[el] fail reason=play")
            }
        case .failure(let reason):
            lastErrorRU = reason
            print("[el] fail reason=\(reason)")
        }

        guard gen == generation else { return }
        lastUsedSystemVoice = true
        lastSource = .system
        await speakSystem(text: text, lang: lang, settings: settings, onStarted: onPlaybackStarted)
    }

    // MARK: - Network / cache

    private enum FetchResult {
        case success(URL)
        case failure(String)
    }

    private func fetchFromNetwork(
        text: String,
        voiceId: String,
        apiKey: String,
        cacheURL: URL,
        params: ElevenLabsVoiceParams,
        settings: AppSettings,
        sync: EosTTSSyncContext?
    ) async -> FetchResult {
        guard let endpoint = URL(string: "\(ElevenLabsConfig.apiRoot)/\(voiceId)") else {
            return .failure("EL ошибка: URL")
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        // Do NOT send `speed` in voice_settings — many accounts return 400 for unknown fields.
        let body: [String: Any] = [
            "text": text,
            "model_id": params.model.rawValue,
            "voice_settings": params.voiceSettingsJSON,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            print("[el] cache miss → HTTP")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("EL ошибка: нет ответа")
            }
            print("[el] status=\(http.statusCode) bytes=\(data.count)")
            guard (200...299).contains(http.statusCode) else {
                // Surface auth failures clearly (never log body if it might echo key hints only — safe codes).
                if http.statusCode == 401 || http.statusCode == 403 {
                    return .failure("EL ошибка: HTTP \(http.statusCode) (ключ)")
                }
                if http.statusCode == 400,
                   let raw = String(data: data, encoding: .utf8),
                   raw.contains("api_key") || raw.contains("authentication") {
                    return .failure("EL ошибка: HTTP 400 (ключ отклонён)")
                }
                return .failure("EL ошибка: HTTP \(http.statusCode)")
            }
            guard data.count > 100 else {
                return .failure("EL ошибка: пустой аудио")
            }
            try data.write(to: cacheURL, options: .atomic)
            ElevenLabsAudioCache.touch(cacheURL)
            ElevenLabsAudioCache.pruneIfNeeded()
            print("[el] cache store \(cacheURL.lastPathComponent)")
            if let sync {
                EosSyncService.postAudioIfConfigured(
                    settings: settings,
                    payload: EosSyncService.AudioPayload(
                        lessonId: sync.lessonId,
                        lineId: sync.lineId,
                        role: sync.role,
                        textEN: sync.textEN,
                        textRU: sync.textRU,
                        voiceId: voiceId,
                        audioBase64: data.base64EncodedString(),
                        contentVersion: sync.contentVersion
                    )
                )
            }
            return .success(cacheURL)
        } catch {
            return .failure("EL ошибка: нет сети")
        }
    }

    private func playFile(url: URL, rate: Float, onStarted: (() -> Void)? = nil) async throws {
        try AudioSessionManager.configureForLesson()
        let p = try AVAudioPlayer(contentsOf: url)
        p.enableRate = true
        p.rate = min(max(rate, 0.5), 2.0)
        p.delegate = self
        player = p
        guard p.play() else {
            throw NSError(domain: "ElevenLabsTTS", code: 2)
        }
        onStarted?()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.finishContinuation = cont
        }
    }

    private func speakSystem(
        text: String,
        lang: SiteVoiceLang,
        settings: AppSettings,
        onStarted: (() -> Void)? = nil
    ) async {
        try? AudioSessionManager.configureForLesson()
        let u = AVSpeechUtterance(string: text)
        switch lang {
        case .en:
            u.voice = AVSpeechSynthesisVoice(language: "en-IE")
                ?? AVSpeechSynthesisVoice(language: "en-GB")
                ?? AVSpeechSynthesisVoice(language: "en-US")
            u.rate = settings.englishRate
        case .ru:
            u.voice = AVSpeechSynthesisVoice(language: "ru-RU")
            u.rate = settings.russianRate
        }
        // Pairs needs instant start — no pre-delay on EN taps/match.
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0.2

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.finishContinuation = cont
            self.fallbackSynth.speak(u)
            onStarted?()
        }
    }

    private func resumeFinish() {
        if let cont = finishContinuation {
            finishContinuation = nil
            cont.resume()
        }
    }
}

extension ElevenLabsTTS: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.resumeFinish()
        }
    }
}

extension ElevenLabsTTS: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeFinish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeFinish() }
    }
}
