import Foundation
import Observation

enum RoleplayLoopPhase: Equatable {
    case idle
    case playingOpponent
    case waitingUser
    case betweenLoops
    case finished
}

/// Step-through roleplay with Loop Mode (repeat until user stops).
@Observable
@MainActor
final class RoleplayLoopEngine {
    let script: RoleplayScript
    /// Slot the learner plays ("a" or "b").
    private(set) var userSlot: String
    private(set) var lineIndex = 0
    private(set) var loopCount = 0
    private(set) var phase: RoleplayLoopPhase = .idle
    private(set) var statusRU = ""
    var speakUserLines = false

    private var runTask: Task<Void, Never>?
    private var userContinue: CheckedContinuation<Void, Never>?

    init(script: RoleplayScript, userSlot: String) {
        self.script = script
        self.userSlot = userSlot == "b" ? "b" : "a"
    }

    var currentLine: RoleplayLine? {
        guard lineIndex >= 0, lineIndex < script.lines.count else { return nil }
        return script.lines[lineIndex]
    }

    var userRoleName: String {
        script.roles.first(where: { $0.slot == userSlot })?.name
            ?? (userSlot == "b" ? "Worker B" : "Worker A")
    }

    var opponentRoleName: String {
        script.roles.first(where: { $0.slot != userSlot })?.name
            ?? (userSlot == "b" ? "Worker A" : "Worker B")
    }

    func setUserSlot(_ slot: String) {
        guard phase == .idle || phase == .finished else { return }
        userSlot = slot == "b" ? "b" : "a"
    }

    func start(settings: AppSettings) {
        stop()
        lineIndex = 0
        loopCount = 0
        phase = .idle
        statusRU = "Старт"
        runTask = Task { await runLoops(settings: settings) }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        ElevenLabsTTS.shared.stop()
        resumeUser()
        phase = .idle
        statusRU = "Стоп"
    }

    /// User finished their turn (said the line or tapped Done).
    func confirmUserTurn() {
        resumeUser()
    }

    private func resumeUser() {
        if let c = userContinue {
            userContinue = nil
            c.resume()
        }
    }

    private func runLoops(settings: AppSettings) async {
        while !Task.isCancelled {
            lineIndex = 0
            statusRU = loopCount == 0 ? "Круг 1" : "Круг \(loopCount + 1)"
            while lineIndex < script.lines.count {
                if Task.isCancelled { return }
                let line = script.lines[lineIndex]
                let isUser = isUserLine(line)

                if isUser {
                    phase = .waitingUser
                    statusRU = "Твоя реплика · \(userRoleName)"
                    if speakUserLines {
                        await speakLine(line, settings: settings)
                    }
                    await waitForUser()
                    if Task.isCancelled { return }
                } else {
                    phase = .playingOpponent
                    statusRU = "Слушай · \(line.role)"
                    await speakLine(line, settings: settings)
                    if Task.isCancelled { return }
                }
                lineIndex += 1
            }

            loopCount += 1
            phase = .betweenLoops
            statusRU = "Круг \(loopCount) готов · ещё раз…"
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        phase = .finished
    }

    private func isUserLine(_ line: RoleplayLine) -> Bool {
        if let role = script.roles.first(where: { $0.name.caseInsensitiveCompare(line.role) == .orderedSame }) {
            return role.slot == userSlot
        }
        // Fallback: alternate by index if names don't match
        let userName = userRoleName
        return line.role.caseInsensitiveCompare(userName) == .orderedSame
    }

    private func speakLine(_ line: RoleplayLine, settings: AppSettings) async {
        let voiceId = script.roles.first(where: {
            $0.name.caseInsensitiveCompare(line.role) == .orderedSame
        })?.voiceId ?? ElevenLabsConfig.voiceRoleA
        await ElevenLabsTTS.shared.speak(
            text: line.en,
            voiceId: voiceId,
            lang: .en,
            settings: settings
        )
    }

    private func waitForUser() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.userContinue = cont
        }
    }
}
