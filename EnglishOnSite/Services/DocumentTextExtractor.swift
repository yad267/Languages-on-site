import Foundation
import zlib

/// Extracts plain text from .txt / .md / .docx (Office Open XML).
enum DocumentTextExtractor {
    static func extract(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "txt", "md", "text", "":
            let data = try Data(contentsOf: url)
            guard let s = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                throw ExtractError.encoding
            }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case "docx":
            return try extractDocx(url)
        default:
            throw ExtractError.unsupported(ext)
        }
    }

    enum ExtractError: LocalizedError {
        case encoding
        case unsupported(String)
        case docxCorrupt
        case docxNoDocument

        var errorDescription: String? {
            switch self {
            case .encoding: return "Не прочитал файл (кодировка)"
            case .unsupported(let e): return "Формат .\(e) — только .txt или .docx"
            case .docxCorrupt: return "DOCX повреждён или не читается"
            case .docxNoDocument: return "В DOCX нет document.xml"
            }
        }
    }

    private static func extractDocx(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let xmlData = try ZipReader.fileData(named: "word/document.xml", in: data) else {
            throw ExtractError.docxNoDocument
        }
        guard let xml = String(data: xmlData, encoding: .utf8) else {
            throw ExtractError.docxCorrupt
        }
        return stripDocxXML(xml)
    }

    private static func stripDocxXML(_ xml: String) -> String {
        var text = xml
        text = text.replacingOccurrences(of: "</w:p>", with: "\n")
        text = text.replacingOccurrences(of: "<w:tab/>", with: "\t")
        text = text.replacingOccurrences(of: "<w:br[^/]*/>", with: "\n", options: .regularExpression)
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }
        text = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Minimal ZIP local-header reader (stored + deflate / raw inflate).
private enum ZipReader {
    static func fileData(named path: String, in zip: Data) throws -> Data? {
        let bytes = [UInt8](zip)
        var offset = 0
        while offset + 30 <= bytes.count {
            let sig = readU32(bytes, offset)
            guard sig == 0x04034b50 else { break }
            let method = Int(readU16(bytes, offset + 8))
            let flags = Int(readU16(bytes, offset + 6))
            let compSize = Int(readU32(bytes, offset + 18))
            let uncompSize = Int(readU32(bytes, offset + 22))
            let nameLen = Int(readU16(bytes, offset + 26))
            let extraLen = Int(readU16(bytes, offset + 28))
            let nameStart = offset + 30
            let nameEnd = nameStart + nameLen
            guard nameEnd <= bytes.count else { return nil }
            let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8) ?? ""
            let dataStart = nameEnd + extraLen

            // Bit 3 = data descriptor; skip unreliable entries
            if (flags & 0x08) != 0 && compSize == 0 {
                offset = dataStart
                continue
            }

            let dataEnd = dataStart + compSize
            guard dataEnd <= bytes.count else { return nil }
            let payload = Data(bytes[dataStart..<dataEnd])
            if name == path || name.hasSuffix("/\(path)") {
                if method == 0 { return payload }
                if method == 8 {
                    return try inflateRaw(payload, hint: max(uncompSize, 4096))
                }
                throw DocumentTextExtractor.ExtractError.docxCorrupt
            }
            offset = dataEnd
        }
        return nil
    }

    private static func readU16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    private static func inflateRaw(_ data: Data, hint: Int) throws -> Data {
        var stream = z_stream()
        var status = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw DocumentTextExtractor.ExtractError.docxCorrupt }
        defer { inflateEnd(&stream) }

        var output = Data()
        output.reserveCapacity(hint)
        let chunkSize = 32_768
        var failed = false

        data.withUnsafeBytes { raw in
            guard let inPtr = raw.bindMemory(to: Bytef.self).baseAddress else {
                failed = true
                return
            }
            stream.next_in = UnsafeMutablePointer(mutating: inPtr)
            stream.avail_in = uInt(data.count)

            repeat {
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                let before = Int(stream.total_out)
                chunk.withUnsafeMutableBytes { outRaw in
                    stream.next_out = outRaw.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                }
                if status != Z_OK && status != Z_STREAM_END {
                    failed = true
                    return
                }
                let produced = Int(stream.total_out) - before
                if produced > 0 {
                    output.append(contentsOf: chunk.prefix(produced))
                }
            } while !failed && status != Z_STREAM_END
        }

        if failed { throw DocumentTextExtractor.ExtractError.docxCorrupt }
        return output
    }
}
