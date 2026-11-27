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

    /// True only when the *effective* runtime key is a Key ID (usable Secrets.local sk_ wins → false).
    static var elevenLabsKeyLooksLikeIdOnly: Bool {
        if hasLocalElevenLabs { return false }
        return looksLikeElevenLabsKeyId(effectiveElevenLabsAPIKey)
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

        // --- ElevenLabs: Secrets.local.swift (Mac) is source of truth when it holds sk_… ---
        // Never seed a Key ID. Do not wipe a usable Keychain secret just because Secrets still has an ID.
        let existingE = sanitizeSecret(KeychainStore.loadElevenLabsAPIKey())
        let secretsIsKeyId = looksLikeElevenLabsKeyId(elevenLabsAPIKey)
        let keychainIsKeyId = looksLikeElevenLabsKeyId(existingE)
        let keychainUsable = isUsableElevenLabsKey(existingE)

        if hasLocalElevenLabs {
            // Always push baked sk_ → Keychain + toggle ON (phone must not re-enter).
            if force || existingE != elevenLabsAPIKey || keychainIsKeyId || !settings.useElevenLabs {
                KeychainStore.saveElevenLabsAPIKey(elevenLabsAPIKey)
                settings.elevenLabsAPIKeyDraft = elevenLabsAPIKey
                settings.useElevenLabs = true
                if keychainIsKeyId {
                    parts.append("EL ID→sk_←Secrets")
                } else if existingE.isEmpty {
                    parts.append("EL→Keychain")
                } else if existingE != elevenLabsAPIKey {
                    parts.append(force ? "EL force←Secrets" : "EL обновлён←Secrets")
                } else {
                    parts.append("EL toggle ON")
                }
                print("[secrets] Secrets.local sk_ → Keychain / toggle ON")
            }
        } else if secretsIsKeyId {
            print("[secrets] ElevenLabs Secrets is Key ID — refuse seed (need sk_… on Mac)")
            parts.append("EL Secrets=ID✗")
            // Soft clear: only remove a Key ID from Keychain. Keep a usable sk_ already on device.
            if keychainIsKeyId {
                KeychainStore.saveElevenLabsAPIKey("")
                settings.elevenLabsAPIKeyDraft = ""
                settings.useElevenLabs = false
                parts.append("EL Keychain ID cleared")
                print("[secrets] cleared Keychain Key ID only")
            } else if keychainUsable, !settings.useElevenLabs {
                settings.useElevenLabs = true
                parts.append("EL Keychain sk_ kept")
            }
        } else if keychainIsKeyId {
            // Secrets empty / not usable, Keychain holds ID → clear ID so UI asks Mac, not fake “has key”.
            KeychainStore.saveElevenLabsAPIKey("")
            settings.elevenLabsAPIKeyDraft = ""
            settings.useElevenLabs = false
            parts.append("EL Keychain ID cleared")
            print("[secrets] cleared Keychain Key ID (Secrets empty)")
        } else if existingE.isEmpty {
            print("[secrets] ElevenLabs Secrets empty — skip")
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
        if hasLocalElevenLabs {
            bits.append("EL из Secrets.local (Mac) ✓ — телефон ввод не нужен")
        } else if looksLikeElevenLabsKeyId(elevenLabsAPIKey) {
            bits.append("EL Secrets.local = Key ID ✗ — вставь sk_… на Mac")
        } else {
            bits.append(hasAnyLocal ? "Secrets.local на Mac (EL пустой)" : "Secrets.local пустой")
        }
        bits.append(KeychainStore.hasGeminiAPIKey() ? "Gemini Keychain ✓" : "Gemini Keychain ✗")
        if hasLocalElevenLabs {
            bits.append("приоритет Mac")
        } else if isUsableElevenLabsKey(KeychainStore.loadElevenLabsAPIKey()) {
            bits.append("EL Keychain ✓")
        } else {
            bits.append("EL Keychain ✗")
        }
        return bits.joined(separator: " · ")
    }
}
