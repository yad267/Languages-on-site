import UIKit
import AudioToolbox

enum CommandFeedback {
    static func acknowledged() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        // Short system click — does not tear down the lesson player.
        AudioServicesPlaySystemSound(1104)
    }
}
