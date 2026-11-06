import Foundation
import SwiftData

@MainActor
enum LibraryStore {
    @discardableResult
    static func add(
        context: ModelContext,
        source: LibrarySource,
        en: String,
        ru: String,
        tipRu: String,
        tag: LibraryTag,
        transcriptRaw: String? = nil,
        itemType: LibraryItemType = .myPhrase,
        audioFileName: String? = nil,
        audioCacheKey: String? = nil
    ) -> LibraryItem {
        let key = LibraryItem.normalizeEN(en)
        if let existing = find(normalizedKey: key, context: context) {
            // Enrich but never wipe known / SRS / audio unless empty.
            if existing.ru.isEmpty, !ru.isEmpty { existing.ru = ru }
            if existing.tipRu.isEmpty, !tipRu.isEmpty { existing.tipRu = tipRu }
            if existing.audioFileName == nil, let audioFileName { existing.audioFileName = audioFileName }
            if existing.audioCacheKey == nil, let audioCacheKey { existing.audioCacheKey = audioCacheKey }
            if existing.itemType == .myPhrase, itemType != .myPhrase {
                existing.itemType = itemType
            }
            try? context.save()
            return existing
        }
        let item = LibraryItem(
            source: source,
            en: en,
            ru: ru,
            tipRu: tipRu,
            tag: tag,
            transcriptRaw: transcriptRaw,
            audioFileName: audioFileName,
            audioCacheKey: audioCacheKey,
            itemType: itemType,
            normalizedKey: key
        )
        context.insert(item)
        try? context.save()
        return item
    }

    static func find(normalizedKey: String, context: ModelContext) -> LibraryItem? {
        let key = LibraryItem.normalizeEN(normalizedKey)
        guard !key.isEmpty else { return nil }
        let descriptor = FetchDescriptor<LibraryItem>()
        guard let all = try? context.fetch(descriptor) else { return nil }
        return all.first { $0.normalizedKey == key || LibraryItem.normalizeEN($0.en) == key }
    }

    static func update(
        _ item: LibraryItem,
        en: String,
        ru: String,
        tipRu: String,
        tag: LibraryTag,
        context: ModelContext
    ) {
        item.en = en
        item.ru = ru
        item.tipRu = tipRu
        item.tag = tag
        item.normalizedKey = LibraryItem.normalizeEN(en)
        try? context.save()
    }

    static func delete(_ item: LibraryItem, context: ModelContext) {
        if let name = item.audioFileName {
            try? FileManager.default.removeItem(at: LibraryAudioStore.fileURL(fileName: name))
        }
        context.delete(item)
        try? context.save()
    }

    static func markLearned(_ item: LibraryItem, context: ModelContext) {
        item.markLearned()
        try? context.save()
    }

    static func markKnown(_ item: LibraryItem, context: ModelContext) {
        item.markKnown(advanceSRS: true)
        try? context.save()
    }

    static func unmarkKnown(_ item: LibraryItem, context: ModelContext) {
        item.unmarkKnown()
        try? context.save()
    }

    static func markReviewFailed(_ item: LibraryItem, context: ModelContext) {
        item.markReviewFailed()
        try? context.save()
    }

    /// Upsert bank unit + set known (one key per normalized EN).
    @discardableResult
    static func setKnown(
        en: String,
        ru: String,
        tipRu: String = "",
        itemType: LibraryItemType,
        source: LibrarySource = .bank,
        known: Bool,
        context: ModelContext
    ) -> LibraryItem {
        let item = add(
            context: context,
            source: source,
            en: en,
            ru: ru,
            tipRu: tipRu,
            tag: .other,
            itemType: itemType
        )
        if known {
            item.markKnown(advanceSRS: item.srsStage == 0)
        } else {
            item.unmarkKnown()
        }
        try? context.save()
        return item
    }

    static func dueItems(_ items: [LibraryItem], limit: Int = 5) -> [LibraryItem] {
        items
            .filter { $0.known && $0.isDue }
            .sorted { $0.nextReviewAt < $1.nextReviewAt }
            .prefix(limit)
            .map { $0 }
    }

    static func isKnown(en: String, items: [LibraryItem]) -> Bool {
        let key = LibraryItem.normalizeEN(en)
        return items.contains { $0.known && ($0.normalizedKey == key || LibraryItem.normalizeEN($0.en) == key) }
    }
}
