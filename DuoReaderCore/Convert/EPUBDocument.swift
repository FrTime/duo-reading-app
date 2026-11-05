import Foundation

/// A book being converted into EPUB: metadata plus chapters of XHTML.
///
/// Formats the reader can't open directly (plain text, Markdown, RTF, HTML)
/// are turned into one of these on import and written out with `EPUBWriter`,
/// so the reader, saved places and highlights only ever deal with EPUB.
public struct EPUBDocument: Equatable, Sendable {
    public struct Chapter: Equatable, Sendable {
        /// Shown in the table of contents. Untitled chapters are left out of it.
        public var title: String?
        /// Well-formed XHTML for the inside of `<body>`.
        public var body: String

        public init(title: String?, body: String) {
            self.title = title
            self.body = body
        }
    }

    public var title: String
    public var authors: [String] = []
    public var language: String = "en"
    public var publisher: String?
    public var summary: String?
    /// Extra `dc:identifier`s, such as an AO3 work URL.
    public var sourceIdentifiers: [String] = []
    /// A cover image (JPEG, PNG or GIF bytes), when the source file has one.
    public var coverImage: Data?
    public var chapters: [Chapter]

    public init(title: String, authors: [String] = [], chapters: [Chapter]) {
        self.title = title
        self.authors = authors
        self.chapters = chapters
    }
}

/// One block of converted text, before it's split into chapters.
public enum TextBlock: Equatable, Sendable {
    /// `inline` is escaped XHTML (may contain `<em>`, `<strong>`, …).
    case paragraph(inline: String)
    case heading(level: Int, text: String)
    case sceneBreak
    /// Already well-formed XHTML (lists, block quotes, code).
    case raw(String)

    /// Splits blocks into chapters at headings of `level` or higher.
    ///
    /// Text before the first such heading becomes an untitled opening chapter.
    /// A book without headings becomes untitled chapters of about
    /// `maxChapterBytes`, because one huge XHTML file is slow to page through.
    public static func chapters(
        from blocks: [TextBlock],
        splitLevel: Int?,
        maxChapterBytes: Int = 120_000
    ) -> [EPUBDocument.Chapter] {
        var chapters: [EPUBDocument.Chapter] = []
        var title: String?
        var body = ""

        func flush() {
            if title != nil || !body.isEmpty {
                chapters.append(.init(title: title, body: body))
            }
            title = nil
            body = ""
        }

        for block in blocks {
            if case .heading(let level, let text) = block, let splitLevel, level <= splitLevel {
                flush()
                title = text
                body = "<h2>\(XHTML.escape(text))</h2>\n"
                continue
            }
            if splitLevel == nil, body.utf8.count >= maxChapterBytes, block.isParagraphLike {
                flush()
            }
            body += block.xhtml + "\n"
        }
        flush()
        return chapters.isEmpty ? [.init(title: nil, body: "<p></p>")] : chapters
    }

    var xhtml: String {
        switch self {
        case .paragraph(let inline): "<p>\(inline)</p>"
        case .heading(let level, let text):
            "<h\(min(max(level + 1, 2), 6))>\(XHTML.escape(text))</h\(min(max(level + 1, 2), 6))>"
        case .sceneBreak: #"<hr class="scene-break"/>"#
        case .raw(let xhtml): xhtml
        }
    }

    private var isParagraphLike: Bool {
        if case .heading = self { return false }
        return true
    }
}

/// Small helpers for writing XHTML by hand.
public enum XHTML {
    /// Escapes text for use in XHTML content or a double-quoted attribute.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // XML 1.0 forbids most control characters, even escaped.
                if scalar.value < 0x20, scalar != "\t", scalar != "\n", scalar != "\r" { continue }
                if (0xFFFE...0xFFFF).contains(scalar.value) { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
