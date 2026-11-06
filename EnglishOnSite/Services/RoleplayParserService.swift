import Foundation

/// Regex-first roleplay parser with Gemini enhancement when available.
enum RoleplayParserService {
    /// Free brief OR Name: script → RoleplayScript.
    static func parse(rawText: String, settings: AppSettings) async throws -> RoleplayScript {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RoleplayParseError.empty }
        guard trimmed.count >= 4 else { throw RoleplayParseError.tooShort }

        // Already a Name: / [Name] dialogue → import/parse path.
        if looksLikeNamedDialogue(trimmed) {
            if let local = parseLocally(trimmed) { return local }
            if settings.geminiEnabledAndReady {
                do {
                    return try await GeminiSiteCoachService.shared.parseRoleplay(text: trimmed)
                } catch {
                    throw RoleplayParseError.gemini(error.localizedDescription)
                }
            }
            throw RoleplayParseError.noLines
        }

        // Free-form brief → generate Supervisor/Installer dialogue.
        if settings.geminiEnabledAndReady {
            do {
                return try await GeminiSiteCoachService.shared.generateRoleplay(brief: trimmed)
            } catch {
                if let stub = generateLocalBrief(trimmed) { return stub }
                throw RoleplayParseError.gemini(error.localizedDescription)
            }
        }

        if let stub = generateLocalBrief(trimmed) { return stub }
        throw RoleplayParseError.gemini("Включи Gemini в Настройках — или вставь диалог с Name:")
    }

    /// «Supervisor: …» / «[Installer] …» style — at least 2 named turns.
    static func looksLikeNamedDialogue(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var hits = 0
        let patterns: [NSRegularExpression] = [
            try! NSRegularExpression(pattern: #"^\[([^\]]{1,40})\]\s*.+"#),
            try! NSRegularExpression(pattern: #"^([^:\-]{1,40})\s*[:\-—–]\s*.+"#),
        ]
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            for re in patterns {
                if let m = re.firstMatch(in: line, range: range),
                   m.numberOfRanges >= 2,
                   let r1 = Range(m.range(at: 1), in: line) {
                    let role = String(line[r1]).trimmingCharacters(in: .whitespaces)
                    if role.count >= 2, role.count <= 40, !looksLikeTimestamp(role) {
                        hits += 1
                        break
                    }
                }
            }
        }
        return hits >= 2
    }

    /// Offline stub from keywords (Simulator / no Gemini).
    static func generateLocalBrief(_ brief: String) -> RoleplayScript? {
        let lower = brief.lowercased()
        let wantsSix = lower.contains("6") || lower.contains("шест")
        let roles = [
            RoleplayRole(name: "Supervisor", slot: "a"),
            RoleplayRole(name: "Installer", slot: "b"),
        ]

        var pairs: [(String, String)] = []
        if lower.contains("tray") || lower.contains("basket") || lower.contains("lay") {
            pairs = [
                ("Can you lay the tray basket down here?", "Можешь положить tray basket сюда?"),
                ("Yes — where exactly?", "Да — куда именно?"),
                ("Next to the Unistrut, on the clean spot.", "Рядом с Unistrut, на чистое место."),
                ("OK, laying it down now.", "Ок, кладу сейчас."),
                ("Mind the edges — don't bend the tray.", "Аккуратно с краями — не гни tray."),
                ("Got it. Basket is down.", "Понял. Basket лежит."),
            ]
        } else if lower.contains("clamp") || lower.contains("болт") || lower.contains("bolt") || lower.contains("подерж") {
            pairs = [
                ("Hold the tray while I fit the clamp.", "Подержи tray, я ставлю clamp."),
                ("Sure — I've got it.", "Конечно — держу."),
                ("Pass me that bolt, please.", "Передай тот болт, пожалуйста."),
                ("Here you go.", "Держи."),
                ("Tighten it — not too hard.", "Затяни — но не сильно."),
                ("Done. Clamp is on.", "Готово. Clamp стоит."),
            ]
        } else if lower.contains("unistrut") || lower.contains("give me a hand") || lower.contains("hand") {
            pairs = [
                ("Give me a hand with the Unistrut.", "Помоги с Unistrut."),
                ("OK — lift on three?", "Ок — поднимаем на три?"),
                ("One, two, three — up.", "Раз, два, три — вверх."),
                ("Hold it while I mark the holes.", "Держи, я отмечу отверстия."),
                ("Marked. You can lower it.", "Отметил. Можно опускать."),
                ("Nice one. Thanks.", "Красава. Спасибо."),
            ]
        } else if lower.contains("containment") || lower.contains("zeb") {
            pairs = [
                ("We need containment on this run.", "Нужен containment на этом участке."),
                ("Zebs and clamps ready?", "Zebs и clamps готовы?"),
                ("Yes — how many metres?", "Да — сколько метров?"),
                ("About six. Start from the riser.", "Около шести. Начинай от riser."),
                ("I'll fix the first clamp.", "Я закреплю первый clamp."),
                ("Good. Keep the line straight.", "Хорошо. Держи линию ровно."),
            ]
        } else {
            pairs = [
                ("Can we run through this job quickly?", "Пройдёмся по работе быстро?"),
                ("Sure — what do you need?", "Конечно — что нужно?"),
                ("Stay safe and call me if stuck.", "Работай аккуратно и зови, если застрянешь."),
                ("Will do. Thanks.", "Сделаю. Спасибо."),
            ]
        }

        if wantsSix, pairs.count > 6 {
            pairs = Array(pairs.prefix(6))
        } else if pairs.count > 8 {
            pairs = Array(pairs.prefix(8))
        } else if pairs.count < 4 {
            while pairs.count < 4 {
                pairs.append(("OK.", "Ок."))
            }
        }

        let lines: [RoleplayLine] = pairs.enumerated().map { idx, p in
            let role = idx % 2 == 0 ? "Supervisor" : "Installer"
            return RoleplayLine(index: idx, role: role, en: p.0, ru: p.1, tipRu: nil)
        }

        let title: String
        if lower.contains("tray") || lower.contains("basket") {
            title = "Tray / basket"
        } else if lower.contains("clamp") || lower.contains("болт") {
            title = "Clamp / bolt"
        } else if lower.contains("unistrut") {
            title = "Unistrut"
        } else if lower.contains("containment") || lower.contains("zeb") {
            title = "Containment"
        } else {
            title = "Диалог с объекта"
        }

        return RoleplayScript(
            id: "rp-\(Int(Date().timeIntervalSince1970))",
            titleRu: title,
            sceneRu: "По запросу: \(String(brief.prefix(80)))",
            roles: roles,
            lines: lines,
            sourceRaw: String(brief.prefix(2000)),
            createdAt: Date()
        )
    }

    // MARK: - Local regex

    static func parseLocally(_ text: String) -> RoleplayScript? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var roleOrder: [String] = []
        var parsed: [(role: String, body: String)] = []

        // Patterns: "Name:", "Name -", "[Name]", "Name —"
        let patterns: [NSRegularExpression] = [
            try! NSRegularExpression(pattern: #"^\[([^\]]{1,40})\]\s*(.+)$"#),
            try! NSRegularExpression(pattern: #"^([^:\-]{1,40})\s*[:\-—–]\s*(.+)$"#),
        ]

        for line in lines {
            var matched = false
            for re in patterns {
                let range = NSRange(line.startIndex..., in: line)
                if let m = re.firstMatch(in: line, range: range),
                   m.numberOfRanges >= 3,
                   let r1 = Range(m.range(at: 1), in: line),
                   let r2 = Range(m.range(at: 2), in: line) {
                    let role = String(line[r1]).trimmingCharacters(in: .whitespaces)
                    let body = String(line[r2]).trimmingCharacters(in: .whitespaces)
                    if !role.isEmpty, body.count >= 2, !looksLikeTimestamp(role) {
                        if !roleOrder.contains(where: { $0.caseInsensitiveCompare(role) == .orderedSame }) {
                            roleOrder.append(role)
                        }
                        parsed.append((role, body))
                        matched = true
                        break
                    }
                }
            }
            if !matched, let last = parsed.last, line.count >= 3 {
                // Continuation of previous turn
                parsed[parsed.count - 1] = (last.role, last.body + " " + line)
            }
        }

        guard parsed.count >= 2 else { return nil }

        // Keep first two distinct roles as A/B; map others to nearest
        let primary = Array(roleOrder.prefix(2))
        let roleA = primary.first ?? "Worker A"
        let roleB = primary.count > 1 ? primary[1] : "Worker B"

        let roles = [
            RoleplayRole(name: roleA, slot: "a"),
            RoleplayRole(name: roleB, slot: "b"),
        ]

        let mapped: [RoleplayLine] = parsed.enumerated().map { idx, item in
            let isA = item.role.caseInsensitiveCompare(roleA) == .orderedSame
                || (item.role.caseInsensitiveCompare(roleB) != .orderedSame && idx % 2 == 0)
            let roleName = isA ? roleA : roleB
            let (en, ru) = splitEnRu(item.body)
            return RoleplayLine(index: idx, role: roleName, en: en, ru: ru, tipRu: nil)
        }

        let title = "Диалог · \(roleA) / \(roleB)"
        return RoleplayScript(
            id: "rp-\(Int(Date().timeIntervalSince1970))",
            titleRu: title,
            sceneRu: "Импортированный диалог с объекта",
            roles: roles,
            lines: mapped,
            sourceRaw: String(text.prefix(2000)),
            createdAt: Date()
        )
    }

    private static func looksLikeTimestamp(_ s: String) -> Bool {
        s.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) != nil
    }

    /// "EN text / RU text" or "EN (RU)" or plain EN
    private static func splitEnRu(_ body: String) -> (String, String) {
        if let r = body.range(of: #"\s+[\/\|]\s+"#, options: .regularExpression) {
            let en = String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let ru = String(body[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !en.isEmpty { return (en, ru.isEmpty ? "(перевод позже)" : ru) }
        }
        if let open = body.lastIndex(of: "("), let close = body.lastIndex(of: ")"),
           open < close {
            let en = String(body[..<open]).trimmingCharacters(in: .whitespaces)
            let ru = String(body[body.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            if PhraseBank.containsCyrillic(ru), !en.isEmpty {
                return (en, ru)
            }
        }
        if PhraseBank.containsCyrillic(body) {
            return (body, body)
        }
        return (body, "(перевод позже)")
    }
}
