import Foundation

/// Seeds / refreshes Keychain from Secrets.local.swift. Never logs key material.
enum AppSecrets {
    /// Trim whitespace/newlines, strip wrapping quotes, drop accidental `Bearer ` prefix.
    /// Never logs the value.
    static func sanitizeSecret(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (key.hasPrefix("\"") && key.hasSuffix("\"")) || (key.hasPrefix("'") && key.hasSuffix("'")) {
            key = String(key.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if key.lowercased().hasPrefix("bearer ") {
            key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return key
    }

    static var geminiAPIKey: String { sanitizeSecret(SecretsLocal.geminiAPIKey) }

    static var elevenLabsAPIKey: String { sanitizeSecret(SecretsLocal.elevenLabsAPIKey) }

    static var hasLocalGemini: Bool { !geminiAPIKey.isEmpty }
    /// True only when Secrets.local holds a usable secret — not an ElevenLabs Key ID.
    static var hasLocalElevenLabs: Bool { isUsableElevenLabsKey(elevenLabsAPIKey) }
    static var hasAnyLocal: Bool { hasLocalGemini || hasLocalElevenLabs }

    /// Runtime TTS key: usable Secrets.local wins over Keychain so a stale Keychain
    /// value cannot silently drive HTTP 401 → AVSpeech after a Secrets rotate.
    /// Key IDs (64 hex) are never treated as a usable secret.
    static var effectiveElevenLabsAPIKey: String {
        if hasLocalElevenLabs { return elevenLabsAPIKey }
        let fromKeychain = sanitizeSecret(KeychainStore.loadElevenLabsAPIKey())
        if isUsableElevenLabsKey(fromKeychain) { return fromKeychain }
        // Surface Key ID for UI warning / lastErrorRU; callers must not call the API with it.
        if looksLikeElevenLabsKeyId(fromKeychain) { return fromKeychain }
        if looksLikeElevenLabsKeyId(elevenLabsAPIKey) { return elevenLabsAPIKey }
        return ""
    }

    /// ElevenLabs rejects key *IDs* (64 hex) with HTTP 400 `invalid_api_key`
    /// ("API key ID used as API key"). Real secrets usually start with `sk_`.
    static func looksLikeElevenLabsKeyId(_ raw: String) -> Bool {
        let key = sanitizeSecret(raw)
        guard !key.isEmpty else { return false }
        if key.lowercased().hasPrefix("sk_") { return false }
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return key.count == 64 && key.unicodeScalars.allSatisfy { hex.contains($0) }
    }

    /// Non-empty and not a mistaken Key ID paste.
    static func isUsableElevenLabsKey(_ raw: String) -> Bool {
        let key = sanitizeSecret(raw)
        return !key.isEmpty && !looksLikeElevenLabsKeyId(key)
    }

    static var elevenLabsKeyLooksLikeIdOnly: Bool {
        looksLikeElevenLabsKeyId(effectiveElevenLabsAPIKey)
            || looksLikeElevenLabsKeyId(elevenLabsAPIKey)
            || looksLikeElevenLabsKeyId(KeychainStore.loadElevenLabsAPIKey())
    }

    /// Startup: fill empty slots; if Secrets non-empty and ≠ Keychain → update Keychain (new key after 400).
    @discardableResult
    static func seedKeychainIfNeeded(into settings: AppSettings) -> String {
        applySecretsToKeychain(into: settings, force: false)
    }

    /// Settings «Перечитать Secrets»: always write non-empty Secrets values into Keychain.
    @discardableResult
    static func rereadSecretsIntoKeychain(into settings: AppSettings) -> String {
        applySecretsToKeychain(into: settings, force: true)
    }

    private static func applySecretsToKeychain(into settings: AppSettings, force: Bool) -> String {
        var parts: [String] = []

        // --- Gemini ---
        let existingG = KeychainStore.loadGeminiAPIKey()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if hasLocalGemini {
            if existingG.isEmpty {
                KeychainStore.saveGeminiAPIKey(geminiAPIKey)
                settings.geminiAPIKeyDraft = geminiAPIKey
                settings.useGemini = true
                parts.append("Gemini→Keychain")
                print("[secrets] seeded Gemini → Keychain")
            } else if force || existingG != geminiAPIKey {
                KeychainStore.saveGeminiAPIKey(geminiAPIKey)
                settings.geminiAPIKeyDraft = geminiAPIKey
                settings.useGemini = true
                parts.append(force ? "Gemini force←Secrets" : "Gemini обновлён←Secrets")
                print("[secrets] updated Gemini Keychain from Secrets force=\(force)")
            } else if !settings.useGemini {
                settings.useGemini = true
                parts.append("Gemini toggle ON")
                print("[secrets] Gemini Keychain matches Secrets → toggle ON")
            }
        } else if existingG.isEmpty {
            print("[secrets] Gemini Secrets empty — skip")
        }

        // --- ElevenLabs (same rules; never seed a Key ID — that caused HTTP 400 forever) ---
        let existingE = sanitizeSecret(KeychainStore.loadElevenLabsAPIKey())
        let secretsIsKeyId = looksLikeElevenLabsKeyId(elevenLabsAPIKey)
        let keychainIsKeyId = looksLikeElevenLabsKeyId(existingE)

        if secretsIsKeyId {
            print("[secrets] ElevenLabs Secrets looks like Key ID — refuse seed (need sk_…)")
            parts.append("EL Secrets=ID✗")
            if keychainIsKeyId || existingE.isEmpty {
                KeychainStore.saveElevenLabsAPIKey("")
                settings.elevenLabsAPIKeyDraft = ""
                settings.useElevenLabs = false
                parts.append("EL Keychain cleared (was ID)")
                print("[secrets] cleared ElevenLabs Keychain Key ID")
            }
        } else if hasLocalElevenLabs {
            if existingE.isEmpty || keychainIsKeyId {
                KeychainStore.saveElevenLabsAPIKey(elevenLabsAPIKey)
                settings.elevenLabsAPIKeyDraft = elevenLabsAPIKey
                settings.useElevenLabs = true
                parts.append(keychainIsKeyId ? "EL ID→sk_←Secrets" : "EL→Keychain")
                print("[secrets] seeded ElevenLabs → Keychain")
            } else if force || existingE != elevenLabsAPIKey {
                KeychainStore.saveElevenLabsAPIKey(elevenLabsAPIKey)
                settings.elevenLabsAPIKeyDraft = elevenLabsAPIKey
                settings.useElevenLabs = true
                parts.append(force ? "EL force←Secrets" : "EL обновлён←Secrets")
                print("[secrets] updated ElevenLabs Keychain from Secrets force=\(force)")
            } else if !settings.useElevenLabs {
                settings.useElevenLabs = true
                parts.append("EL toggle ON")
                print("[secrets] ElevenLabs Keychain matches Secrets → toggle ON")
            }
        } else {
            if keychainIsKeyId {
                KeychainStore.saveElevenLabsAPIKey("")
                settings.elevenLabsAPIKeyDraft = ""
                settings.useElevenLabs = false
                parts.append("EL Keychain cleared (was ID)")
                print("[secrets] cleared ElevenLabs Keychain Key ID (Secrets empty)")
            } else if existingE.isEmpty {
                print("[secrets] ElevenLabs Secrets empty — skip")
            }
        }

        let g = KeychainStore.loadGeminiAPIKey()
        let e = KeychainStore.loadElevenLabsAPIKey()
        if !g.isEmpty { settings.geminiAPIKeyDraft = g }
        if !e.isEmpty { settings.elevenLabsAPIKeyDraft = e }

        let gMatch = hasLocalGemini && !g.isEmpty && g == geminiAPIKey
        let eMatch = hasLocalElevenLabs && !e.isEmpty && e == elevenLabsAPIKey
        print(
            "[secrets] status geminiKeychain=\(!g.isEmpty) elKeychain=\(!e.isEmpty) gMatchSecrets=\(gMatch) eMatchSecrets=\(eMatch) useEL=\(settings.useElevenLabs) force=\(force)"
        )

        if parts.isEmpty {
            if eMatch, gMatch || !hasLocalGemini {
                return "Keychain = Secrets · EL ✓ · toggle \(settings.useElevenLabs ? "ON" : "OFF")"
            }
            return "Gemini Keychain \(g.isEmpty ? "✗" : "✓") · EL Keychain \(e.isEmpty ? "✗" : "✓")"
        }
        return "Secrets→Keychain: \(parts.joined(separator: ", "))"
    }

    static var settingsStatusLine: String {
        var bits: [String] = []
        bits.append(hasAnyLocal ? "Secrets.local на Mac ✓" : "Secrets.local пустой")
        bits.append(KeychainStore.hasGeminiAPIKey() ? "Gemini Keychain ✓" : "Gemini Keychain ✗")
        if KeychainStore.hasElevenLabsAPIKey() {
            let match = hasLocalElevenLabs
                && KeychainStore.loadElevenLabsAPIKey() == elevenLabsAPIKey
            bits.append(match ? "EL Keychain ✓ из Secrets" : "EL Keychain ✓")
        } else {
            bits.append("EL Keychain ✗")
        }
        return bits.joined(separator: " · ")
    }
}
