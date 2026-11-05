import Foundation

/// Converts `.txt` books. Paragraphs are separated by blank lines (hard-wrapped
/// lines inside a paragraph are joined), or are one per line when the file has
/// no blank lines at all. Lines like "Chapter 3" start chapters, and Project
/// Gutenberg's "Title:" and "Author:" header lines fill in the metadata.
public struct PlainTextConverter: BookConverter {
    public init() {}

    public func document(from url: URL) async throws -> EPUBDocument {
        let text = try BookConverters.decodeText(BookConverters.readSource(url))
        return Self.document(fromText: text, fallbackTitle: BookConverters.title(for: url))
    }

    static func document(fromText text: String, fallbackTitle: String) -> EPUBDocument {
        let header = Self.header(in: text)
        let blocks = Self.blocks(from: text)
        let hasHeadings = blocks.contains { if case .heading = $0 { true } else { false } }
        var document = EPUBDocument(
            title: header.title ?? fallbackTitle,
            authors: header.author.map { [$0] } ?? [],
            chapters: TextBlock.chapters(from: blocks, splitLevel: hasHeadings ? 1 : nil)
        )
        if let language = header.language { document.language = language }
        return document
    }

    static func blocks(from text: String) -> [TextBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let blankSeparated = lines.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        var blocks: [TextBlock] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            blocks.append(.paragraph(inline: XHTML.escape(joined)))
            paragraph = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
            } else if ProseHeuristics.isSceneBreak(trimmed) {
                flush()
                blocks.append(.sceneBreak)
            } else if paragraph.isEmpty, ProseHeuristics.isChapterHeading(trimmed) {
                blocks.append(.heading(level: 1, text: trimmed))
            } else {
                paragraph.append(trimmed)
                if !blankSeparated { flush() }
            }
        }
        flush()
        return blocks
    }

    struct Header: Equatable {
        var title: String?
        var author: String?
        var language: String?
    }

    /// Project Gutenberg-style "Key: value" lines near the top of the file.
    static func header(in text: String) -> Header {
        var header = Header()
        for line in text.split(separator: "\n", maxSplits: 80, omittingEmptySubsequences: true).prefix(80) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.count <= 200 else { continue }
            switch parts[0].trimmingCharacters(in: .whitespaces).lowercased() {
            case "title" where header.title == nil: header.title = value
            case "author" where header.author == nil: header.author = value
            case "language" where header.language == nil:
                header.language = Locale.LanguageCode(value.lowercased()).isISOLanguage ? value.lowercased()
                    : Locale.LanguageCode.code(named: value)
            default: break
            }
        }
        return header
    }
}

private extension Locale.LanguageCode {
    /// "English" → "en", using English names, for Gutenberg headers.
    static func code(named name: String) -> String? {
        let english = Locale(identifier: "en")
        return Locale.LanguageCode.isoLanguageCodes.first {
            english.localizedString(forLanguageCode: $0.identifier)?.caseInsensitiveCompare(name) == .orderedSame
        }?.identifier
    }
}
