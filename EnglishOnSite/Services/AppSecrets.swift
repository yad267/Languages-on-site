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
    static var hasLocalElevenLabs: Bool { !elevenLabsAPIKey.isEmpty }
    static var hasAnyLocal: Bool { hasLocalGemini || hasLocalElevenLabs }

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

        // --- ElevenLabs (same rules; fixes stale Keychain after owner rotates Secrets) ---
        let existingE = KeychainStore.loadElevenLabsAPIKey()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if hasLocalElevenLabs {
            if existingE.isEmpty {
                KeychainStore.saveElevenLabsAPIKey(elevenLabsAPIKey)
                settings.elevenLabsAPIKeyDraft = elevenLabsAPIKey
                settings.useElevenLabs = true
                parts.append("EL→Keychain")
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
