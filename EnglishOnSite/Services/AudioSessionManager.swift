import AVFoundation

/// Avoids repeated `setCategory` / `setActive` storms when TTS and STT flip every line.
enum AudioSessionManager {
    private enum Mode: Equatable {
        case lesson
        case recording
    }

    private static var activeMode: Mode?
    private static var isActive = false

    static func configureForLesson() throws {
        try apply(.lesson) {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
        }
    }

    /// STT / mic: playAndRecord with measurement-friendly mode + speaker.
    static func configureForRecording() throws {
        try apply(.recording) {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .duckOthers]
            )
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
        activeMode = nil
    }

    private static func apply(_ mode: Mode, configure: () throws -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        if activeMode != mode {
            try configure()
            activeMode = mode
        }
        if !isActive {
            try session.setActive(true, options: mode == .lesson ? .notifyOthersOnDeactivation : [])
            isActive = true
        }
    }
}
