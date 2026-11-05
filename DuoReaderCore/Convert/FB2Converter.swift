import Foundation

/// Converts FictionBook 2 (`.fb2`) books: sections become chapters (nested
/// sections become sub-headings), with emphasis, poems, epigraphs, the cover
/// image and the title-info metadata (authors, series, annotation, language).
///
/// FB2 files often declare a legacy encoding such as windows-1251; the XML
/// parser honours the declaration, so the bytes are passed through as-is.
public struct FB2Converter: BookConverter {
    public init() {}

    public func document(from url: URL) async throws -> EPUBDocument {
        let data = try BookConverters.readSource(url)
        guard let document = Self.document(fromFB2: data, fallbackTitle: BookConverters.title(for: url)) else {
            throw ConversionError.unreadable
        }
        return document
    }

    static func document(fromFB2 data: Data, fallbackTitle: String) -> EPUBDocument? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        guard parser.parse() || !reader.blocks.isEmpty, reader.sawFictionBook else { return nil }

        let hasHeadings = reader.blocks.contains { if case .heading = $0 { true } else { false } }
        var document = EPUBDocument(
            title: reader.bookTitle ?? fallbackTitle,
            authors: reader.authors,
            chapters: TextBlock.chapters(from: reader.blocks, splitLevel: hasHeadings ? 1 : nil)
        )
        if !reader.notes.isEmpty {
            document.chapters.append(.init(
                title: String(localized: "Notes"),
                body: "<h2>\(XHTML.escape(String(localized: "Notes")))</h2>\n" + reader.notes.map(\.xhtml).joined(separator: "\n")
            ))
        }
        document.summary = reader.annotation
        if let language = reader.language { document.language = language }
        if let coverID = reader.coverID, let base64 = reader.binaries[coverID] {
            document.coverImage = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
        }
        return document
    }

    /// Streams the XML into blocks and metadata.
    private final class Reader: NSObject, XMLParserDelegate {
        var sawFictionBook = false
        var bookTitle: String?
        var authors: [String] = []
        var annotation: String?
        var language: String?
        var coverID: String?
        var binaries: [String: String] = [:]
        var blocks: [TextBlock] = []
        var notes: [TextBlock] = []

        private var stack: [String] = []
        private var sectionDepth = 0
        private var inNotesBody = false
        private var text = ""
        private var inline = ""
        private var titleParts: [String] = []
        private var authorParts: [String: String] = [:]
        private var binaryID: String?

        private func inside(_ name: String) -> Bool { stack.contains(name) }
        private var inTitleInfo: Bool { inside("title-info") }

        private func emit(_ block: TextBlock) {
            if inNotesBody { notes.append(block) } else { blocks.append(block) }
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let element = name.split(separator: ":").last.map(String.init) ?? name
            if element == "FictionBook" { sawFictionBook = true }
            stack.append(element)
            text = ""

            switch element {
            case "body":
                inNotesBody = attributes["name"] == "notes"
            case "section" where inside("body"):
                sectionDepth += 1
            case "title" where inside("body"):
                titleParts = []
            case "p", "v", "subtitle", "text-author":
                inline = ""
            case "emphasis": inline += "<em>"
            case "strong": inline += "<strong>"
            case "strikethrough": inline += "<del>"
            case "sub": inline += "<sub>"
            case "sup": inline += "<sup>"
            case "code": inline += "<code>"
            case "image" where inside("coverpage"):
                let href = attributes["l:href"] ?? attributes["xlink:href"] ?? attributes["href"]
                coverID = href.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            case "binary":
                binaryID = attributes["id"]
            case "author" where inTitleInfo:
                authorParts = [:]
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
            if inside("body") { inline += XHTML.escape(string) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let element = name.split(separator: ":").last.map(String.init) ?? name
            defer { if !stack.isEmpty { stack.removeLast() } }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if inTitleInfo {
                switch element {
                case "book-title": bookTitle = value.isEmpty ? nil : value
                case "first-name", "middle-name", "last-name", "nickname": authorParts[element] = value
                case "author":
                    let full = ["first-name", "middle-name", "last-name"].compactMap { authorParts[$0] }
                        .filter { !$0.isEmpty }.joined(separator: " ")
                    let name = full.isEmpty ? authorParts["nickname"] ?? "" : full
                    if !name.isEmpty { authors.append(name) }
                case "p" where inside("annotation"):
                    annotation = [annotation, value].compactMap { $0 }.joined(separator: "\n")
                case "lang": language = value.isEmpty ? nil : value
                default: break
                }
                text = ""
                return
            }

            switch element {
            case "binary":
                if let binaryID { binaries[binaryID] = text }
                binaryID = nil
            case "emphasis": inline += "</em>"
            case "strong": inline += "</strong>"
            case "strikethrough": inline += "</del>"
            case "sub": inline += "</sub>"
            case "sup": inline += "</sup>"
            case "code": inline += "</code>"
            case "p" where inside("body"):
                let content = inline.trimmingCharacters(in: .whitespacesAndNewlines)
                if stack.dropLast().contains("title") {
                    titleParts.append(value)
                } else if !content.isEmpty {
                    if stack.dropLast().contains("epigraph") || stack.dropLast().contains("cite") {
                        emit(.raw("<blockquote><p>\(content)</p></blockquote>"))
                    } else {
                        emit(.paragraph(inline: content))
                    }
                }
            case "v":
                let content = inline.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty { emit(.raw(#"<p class="verse">\#(content)</p>"#)) }
            case "subtitle", "text-author":
                let content = inline.trimmingCharacters(in: .whitespacesAndNewlines)
                if ProseHeuristics.isSceneBreak(value) {
                    emit(.sceneBreak)
                } else if !content.isEmpty {
                    emit(.raw("<p><strong>\(content)</strong></p>"))
                }
            case "title" where inside("body"):
                let heading = titleParts.filter { !$0.isEmpty }.joined(separator: " ")
                // A section title is a heading; the body's own title repeats the book title.
                if sectionDepth > 0, !heading.isEmpty {
                    emit(.heading(level: sectionDepth, text: heading))
                } else if bookTitle == nil, !heading.isEmpty {
                    bookTitle = heading
                }
            case "section" where inside("body"):
                sectionDepth = max(0, sectionDepth - 1)
            case "body":
                inNotesBody = false
            default: break
            }
            text = ""
        }
    }
}
