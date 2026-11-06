import Foundation

/// Shared WatchConnectivity payload types (iOS + watchOS).
enum WCMsgType: String, Codable {
    case ping
    case settingsPush
    case translate
    case remember
    case reviewNext
    case lessonCommand
    /// Watch recorded audio → iPhone SFSpeech (Speech.framework not on watchOS).
    case recognizeAudio
    case result
    case error
}

struct WCEnvelope: Codable {
    var type: String
    var requestId: String
    var payload: [String: String]
}

struct WCSettingsPayload: Codable {
    var geminiEnabled: Bool
    var rememberSeconds: Int
    var translateSeconds: Int
    var enSpeechRate: Float
    var rememberLocale: String
    var stopWords: String
    var pauseWords: String
    var resumeWords: String
    var repeatWords: String
    var translateWords: String
    var rememberWords: String
}

struct WCPhraseResult: Codable {
    var requestId: String
    var en: String
    var ru: String
    var tipRu: String
    var source: String // offline | gemini
    var colloquialNoteRu: String?
    var transcript: String?
    var tag: String?
}

enum WCLessonCommand: String, Codable {
    case stop, pause, resume, next
}
