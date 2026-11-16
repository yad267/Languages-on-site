import Foundation
import UIKit
import Vision

#if canImport(MLKitTranslate)
import MLKitTranslate
#endif
#if canImport(MLKitTextRecognition)
import MLKitTextRecognition
import MLKitVision
#endif

enum MLKitOfflineError: LocalizedError, Equatable {
    case unavailable
    case modelMissing
    case downloadFailed(String)
    case emptyText
    case ocrEmpty
    case translateFailed(String)

    var shortRU: String {
        switch self {
        case .unavailable:
            return "Офлайн ML Kit недоступен в этой сборке"
        case .modelMissing:
            return "Скачай офлайн-модель (Wi‑Fi) — Офлайн в переводчике"
        case .downloadFailed(let s):
            return "Не скачал модель: \(s)"
        case .emptyText:
            return "Пустой текст"
        case .ocrEmpty:
            return "Не разобрал текст на фото"
        case .translateFailed(let s):
            return "Офлайн-перевод не вышел: \(s)"
        }
    }

    var errorDescription: String? { shortRU }
}

/// On-device Google ML Kit Translate (+ Vision/ML Kit OCR for photos).
/// Language packs (~30 MB each) download on first use; RU is always the target.
@MainActor
final class MLKitOfflineTranslateService: ObservableObject {
    static let shared = MLKitOfflineTranslateService()

    @Published private(set) var statusRU: String = ""
    @Published private(set) var isDownloading = false

    var isLinked: Bool {
        #if canImport(MLKitTranslate)
        true
        #else
        false
        #endif
    }

    /// Ensure source + Russian models are on device. Shows RU status for UI.
    func prepareModels(source: TranslatorSourceLanguage) async -> Bool {
        #if canImport(MLKitTranslate)
        isDownloading = true
        statusRU = "Скачиваю офлайн \(source.shortCode)→RU…"
        defer {
            isDownloading = false
        }
        do {
            try await downloadPair(source: source)
            statusRU = "Офлайн \(source.shortCode)→RU готов"
            return true
        } catch {
            statusRU = (error as? MLKitOfflineError)?.shortRU ?? error.localizedDescription
            return false
        }
        #else
        statusRU = MLKitOfflineError.unavailable.shortRU
        return false
        #endif
    }

    func translateText(
        _ text: String,
        source: TranslatorSourceLanguage
    ) async throws -> TranslationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MLKitOfflineError.emptyText }

        #if canImport(MLKitTranslate)
        let ready = await prepareModels(source: source)
        guard ready else { throw MLKitOfflineError.modelMissing }

        let translated = try await runTranslate(trimmed, source: source)
        return TranslationResult(
            sourceText: trimmed,
            translatedText: translated,
            sourceIsRussian: false,
            matched: true,
            tipRu: "Офлайн ML Kit · \(source.shortCode)→RU",
            tag: .other,
            fallbackSpokenRU: nil,
            viaGemini: false
        )
        #else
        throw MLKitOfflineError.unavailable
        #endif
    }

    /// Photo: OCR (ML Kit Text Recognition if linked, else Vision) → ML Kit Translate → RU.
    func translatePhoto(
        imageJPEG: Data,
        caption: String,
        source: TranslatorSourceLanguage
    ) async throws -> TranslationResult {
        #if canImport(MLKitTranslate)
        let ocr = try await recognizeText(imageJPEG: imageJPEG)
        let captionTrim = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceText: String
        if !ocr.isEmpty {
            sourceText = ocr
        } else if !captionTrim.isEmpty {
            sourceText = captionTrim
        } else {
            throw MLKitOfflineError.ocrEmpty
        }

        let ready = await prepareModels(source: source)
        guard ready else { throw MLKitOfflineError.modelMissing }
        let ru = try await runTranslate(sourceText, source: source)

        let photo = PhotoIdentifyResult(
            nameEN: source == .english ? String(sourceText.prefix(80)) : "",
            nameRU: String(ru.prefix(80)),
            kind: "label",
            confidence: "medium",
            ocrText: ocr,
            translationRU: ru,
            translationEN: source == .english ? sourceText : "",
            documentGuess: "",
            summaryRU: "Офлайн OCR + ML Kit · \(source.shortCode)→RU",
            keyFields: [],
            siteTipEN: "",
            siteTipRU: "",
            unclear: ocr.isEmpty
        )

        return TranslationResult(
            sourceText: sourceText,
            translatedText: ru,
            sourceIsRussian: false,
            matched: true,
            tipRu: photo.summaryRU,
            tag: .other,
            fallbackSpokenRU: nil,
            viaGemini: false,
            photo: photo
        )
        #else
        throw MLKitOfflineError.unavailable
        #endif
    }

    // MARK: - Internals

    #if canImport(MLKitTranslate)
    private func mlLanguage(for source: TranslatorSourceLanguage) -> TranslateLanguage {
        switch source {
        case .english: return .english
        case .spanish: return .spanish
        case .german: return .german
        case .french: return .french
        case .portuguese: return .portuguese
        }
    }

    private func downloadPair(source: TranslatorSourceLanguage) async throws {
        let options = TranslatorOptions(
            sourceLanguage: mlLanguage(for: source),
            targetLanguage: .russian
        )
        let translator = Translator.translator(options: options)
        let conditions = ModelDownloadConditions(
            allowsCellularAccess: false,
            allowsBackgroundDownloading: true
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            translator.downloadModelIfNeeded(with: conditions) { error in
                if let error {
                    cont.resume(throwing: MLKitOfflineError.downloadFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            }
        }
    }

    private func runTranslate(_ text: String, source: TranslatorSourceLanguage) async throws -> String {
        let options = TranslatorOptions(
            sourceLanguage: mlLanguage(for: source),
            targetLanguage: .russian
        )
        let translator = Translator.translator(options: options)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            translator.translate(text) { result, error in
                if let error {
                    cont.resume(throwing: MLKitOfflineError.translateFailed(error.localizedDescription))
                    return
                }
                let out = (result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if out.isEmpty {
                    cont.resume(throwing: MLKitOfflineError.translateFailed("empty"))
                } else {
                    cont.resume(returning: out)
                }
            }
        }
    }
    #endif

    private func recognizeText(imageJPEG: Data) async throws -> String {
        #if canImport(MLKitTextRecognition)
        if let ml = try? await recognizeWithMLKit(imageJPEG: imageJPEG), !ml.isEmpty {
            return ml
        }
        #endif
        return try await recognizeWithVision(imageJPEG: imageJPEG)
    }

    #if canImport(MLKitTextRecognition)
    private func recognizeWithMLKit(imageJPEG: Data) async throws -> String {
        guard let ui = UIImage(data: imageJPEG) else { return "" }
        let visionImage = VisionImage(image: ui)
        visionImage.orientation = ui.imageOrientation
        let recognizer = TextRecognizer.textRecognizer()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            recognizer.process(visionImage) { result, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                let text = (result?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: text)
            }
        }
    }
    #endif

    private func recognizeWithVision(imageJPEG: Data) async throws -> String {
        guard let cg = UIImage(data: imageJPEG)?.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Latin scripts cover EN/ES/DE/FR/PT.
        request.recognitionLanguages = ["en-US", "es-ES", "de-DE", "fr-FR", "pt-PT"]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([request])
        let texts = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
