import Foundation
import Observation

/// Lets WatchConnectivity control the active lesson player (if any).
@MainActor
@Observable
final class PhoneLessonRelay {
    static let shared = PhoneLessonRelay()

    weak var player: LessonPlayer?

    func handle(_ command: WCLessonCommand) {
        guard let player else { return }
        switch command {
        case .stop:
            player.stop()
        case .pause:
            player.pause()
        case .resume:
            player.resume()
        case .next:
            player.skipForward()
        }
    }
}
