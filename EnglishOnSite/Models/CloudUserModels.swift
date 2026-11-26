import Foundation
import SwiftData

/// Synced non-secret app preferences (one logical row; CloudKit may temporarily duplicate — we keep latest `updatedAt`).
@Model
final class SyncedPrefsRecord {
    var recordKey: String
    var payloadJSON: String
    var updatedAt: Date

    init(recordKey: String = "prefs", payloadJSON: String = "{}", updatedAt: Date = Date()) {
        self.recordKey = recordKey
        self.payloadJSON = payloadJSON
        self.updatedAt = updatedAt
    }
}

/// Generic synced id marks: pairs known, completed lessons, etc.
@Model
final class SyncedMarkRecord {
    var namespace: String
    var value: String
    var updatedAt: Date

    init(namespace: String = "", value: String = "", updatedAt: Date = Date()) {
        self.namespace = namespace
        self.value = value
        self.updatedAt = updatedAt
    }
}

/// Tutor «почему» history entries.
@Model
final class SyncedWhyRecord {
    var id: UUID
    var question: String
    var answer: String
    var createdAt: Date

    init(id: UUID = UUID(), question: String = "", answer: String = "", createdAt: Date = Date()) {
        self.id = id
        self.question = question
        self.answer = answer
        self.createdAt = createdAt
    }
}

/// Opaque JSON blobs: extra verbs, gloss cache, future user payloads.
@Model
final class SyncedBlobRecord {
    var kind: String
    var payloadJSON: String
    var updatedAt: Date

    init(kind: String = "", payloadJSON: String = "{}", updatedAt: Date = Date()) {
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.updatedAt = updatedAt
    }
}
