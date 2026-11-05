import Foundation

/// Turns a file the reader can't open directly into an `EPUBDocument`.
public protocol BookConverter: Sendable {
    func document(from url: URL) async throws -> EPUBDocument
}

public enum ConversionError: Error, Equatable {
    /// Over `BookConverters.maxSourceBytes`.
    case tooLarge
    /// Not text, or not the format its extension says.
    case unreadable
}

public enum BookConverters {
    /// Text formats are small; anything this big is almost certainly not a book.
    public static let maxSourceBytes = 50 * 1024 * 1024

    /// The converter for a format, or nil when it's read natively or not supported yet.
    public static func converter(for format: BookFormat) -> (any BookConverter)? {
        switch format {
        case .txt: PlainTextConverter()
        case .markdown: MarkdownConverter()
        case .rtf: RTFConverter()
        default: nil
        }
    }

    /// Reads the file, refusing anything over `maxSourceBytes`.
    static func readSource(_ url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxSourceBytes else { throw ConversionError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maxSourceBytes else { throw ConversionError.tooLarge }
        return data
    }

    /// Decodes text in whatever encoding it's most likely in: UTF-8 (with or
    /// without a BOM), UTF-16 with a BOM, then Windows-1252, which is what
    /// older plain-text books usually are. Line endings become `\n`.
    static func decodeText(_ data: Data) throws -> String {
        let text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let decoded = String(data: data, encoding: .utf16) else { throw ConversionError.unreadable }
            text = decoded
        } else if let decoded = String(data: data, encoding: .utf8) {
            text = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
        } else if let decoded = String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) {
            text = decoded
        } else {
            throw ConversionError.unreadable
        }
        // Lots of NULs means a binary file with a text extension.
        if text.utf8.prefix(4096).filter({ $0 == 0 }).count > 8 { throw ConversionError.unreadable }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// The title to use when the file itself doesn't name one.
    static func title(for url: URL) -> String {
        BookMetadata.fallbackTitle(for: url)
    }
}

/// Recognises chapter headings and scene breaks in plain prose.
enum ProseHeuristics {
    /// "Chapter 12", "CHAPTER TWELVE: The Storm", "Part One", "Prologue", "Epilogue", …
    static func isChapterHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 80, !trimmed.hasSuffix(",") else { return false }
        return trimmed.wholeMatch(of: headingPattern) != nil
    }

    /// "***", "* * *", "#", "~~~", "———", "-o-" style breaks between scenes.
    static func isSceneBreak(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 20 else { return false }
        return trimmed.allSatisfy { "*#~-–—_=•·o0x+ ".contains($0) }
            && trimmed.contains(where: { "*#~-–—_=•·".contains($0) })
    }

    nonisolated(unsafe) private static let headingPattern =
        /(chapter|part|book|volume|prologue|epilogue|interlude|afterword|foreword|preface)(\s+([0-9]+|[ivxlcdm]+|[a-z\-]+))?\s*([.:\-–—]\s*.*)?/.ignoresCase()
}
