import Foundation
import ReadiumZIPFoundation

/// Converts Word (`.docx`) books: heading styles start chapters, and bold,
/// italic, underline and strikethrough are kept. The title and author come
/// from the document properties (File > Properties in Word), then from a
/// "Title" styled paragraph, then from the file name.
///
/// Style IDs are localised in non-English Word ("Überschrift1"), so headings
/// are recognised by the style *name* in `styles.xml` ("heading 1"), which
/// Word always writes in English.
public struct DOCXConverter: BookConverter {
    public init() {}

    public func document(from url: URL) async throws -> EPUBDocument {
        let archive: Archive
        do {
            archive = try await Archive(url: url, accessMode: .read)
        } catch {
            throw ConversionError.unreadable
        }
        let limit = Int64(BookConverters.maxSourceBytes)
        guard let body = try? await EPUBMetadataReader.data(at: "word/document.xml", in: archive, limit: limit) else {
            throw ConversionError.unreadable
        }
        let styles = (try? await EPUBMetadataReader.data(at: "word/styles.xml", in: archive, limit: limit))
            .map(Self.styleNames) ?? [:]
        let core = (try? await EPUBMetadataReader.data(at: "docProps/core.xml", in: archive)).map(Self.coreProperties) ?? [:]

        let parsed = Self.blocks(fromDocument: body, styleNames: styles)
        let levels = parsed.blocks.compactMap { if case .heading(let level, _) = $0 { level } else { nil } }
        var document = EPUBDocument(
            title: core["title"] ?? parsed.title ?? Self.leadingHeading(parsed.blocks) ?? parsed.styledTitle
                ?? BookConverters.title(for: url),
            authors: (core["creator"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            chapters: TextBlock.chapters(from: parsed.blocks, splitLevel: levels.min())
        )
        document.summary = core["description"]
        let plain = parsed.blocks.prefix(40).compactMap { if case .paragraph(let inline) = $0 { inline } else { nil } }.joined(separator: " ")
        if let language = core["language"] ?? BookConverters.detectLanguage(plain) { document.language = language }
        return document
    }

    /// A document that opens with a heading is usually titled by it, when
    /// neither the properties nor a Title paragraph name it.
    static func leadingHeading(_ blocks: [TextBlock]) -> String? {
        if case .heading(_, let text)? = blocks.first { text } else { nil }
    }

    // MARK: - Styles and properties

    /// Style ID → lowercased style name, from `word/styles.xml`.
    static func styleNames(_ data: Data) -> [String: String] {
        let reader = StyleReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return reader.names
    }

    /// `title`, `creator`, `description` and `language` from `docProps/core.xml`.
    static func coreProperties(_ data: Data) -> [String: String] {
        let reader = CoreReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return reader.values
    }

    /// The heading level for a style name, 0 for the document title, nil for body text.
    static func headingLevel(styleName: String) -> Int? {
        if styleName == "title" { return 0 }
        guard styleName.hasPrefix("heading "), let level = Int(styleName.dropFirst(8)), (1...6).contains(level) else { return nil }
        return level
    }

    // MARK: - Body

    struct Parsed {
        var title: String?
        var blocks: [TextBlock]
        /// A short first paragraph set in bold or large type, which is how
        /// documents without styles (Pages, TextEdit, textutil) mark a title.
        var styledTitle: String?
    }

    static func blocks(fromDocument data: Data, styleNames: [String: String]) -> Parsed {
        let reader = BodyReader(styleNames: styleNames)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return Parsed(title: reader.title, blocks: reader.blocks, styledTitle: reader.styledTitle)
    }

    private final class BodyReader: NSObject, XMLParserDelegate {
        let styleNames: [String: String]
        var title: String?
        var styledTitle: String?
        var blocks: [TextBlock] = []

        private var styleName = ""
        private var paragraphXHTML = ""
        private var paragraphText = ""
        private var runText = ""
        private var bold = false, italic = false, underline = false, strike = false
        /// Font size in half-points (`w:sz`), 0 when the run doesn't set one.
        private var runSize = 0
        private var paragraphAllBold = true
        private var paragraphMaxSize = 0
        private var inText = false
        private var inRunProperties = false
        /// Text boxes nest whole paragraphs inside a run; only the outermost
        /// paragraph starts and finishes one.
        private var paragraphDepth = 0
        /// Word writes text boxes twice; the `mc:Fallback` copy is skipped.
        private var fallbackDepth = 0

        init(styleNames: [String: String]) { self.styleNames = styleNames }

        private func isOn(_ attributes: [String: String]) -> Bool {
            let value = attributes["w:val"] ?? "true"
            return !["0", "false", "none"].contains(value)
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "mc:Fallback" { fallbackDepth += 1 }
            guard fallbackDepth == 0 else { return }
            switch name {
            case "w:p":
                paragraphDepth += 1
                if paragraphDepth == 1 {
                    styleName = ""
                    paragraphXHTML = ""
                    paragraphText = ""
                    paragraphAllBold = true
                    paragraphMaxSize = 0
                }
            case "w:pStyle" where paragraphDepth == 1:
                let id = attributes["w:val"] ?? ""
                styleName = styleNames[id] ?? id.lowercased()
            case "w:r":
                bold = false; italic = false; underline = false; strike = false
                runSize = 0
                runText = ""
            case "w:rPr": inRunProperties = true
            case "w:b" where inRunProperties: bold = isOn(attributes)
            case "w:i" where inRunProperties: italic = isOn(attributes)
            case "w:u" where inRunProperties: underline = isOn(attributes)
            case "w:strike" where inRunProperties: strike = isOn(attributes)
            case "w:sz" where inRunProperties: runSize = Int(attributes["w:val"] ?? "") ?? 0
            case "w:t": inText = true
            case "w:tab": runText += " "
            case "w:br" where attributes["w:type"] == nil || attributes["w:type"] == "textWrapping":
                flushRun()
                paragraphXHTML += "<br/>"
                paragraphText += "\n"
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText, fallbackDepth == 0 { runText += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "mc:Fallback" {
                fallbackDepth -= 1
                return
            }
            guard fallbackDepth == 0 else { return }
            switch name {
            case "w:t": inText = false
            case "w:rPr": inRunProperties = false
            case "w:r": flushRun()
            case "w:p":
                paragraphDepth -= 1
                if paragraphDepth == 0 {
                    finishParagraph()
                } else {
                    // A text box's paragraph inside this one: keep it as a line.
                    paragraphXHTML += "<br/>"
                    paragraphText += "\n"
                }
            default: break
            }
        }

        private func flushRun() {
            guard !runText.isEmpty else { return }
            var html = XHTML.escape(runText)
            if italic { html = "<em>\(html)</em>" }
            if bold { html = "<strong>\(html)</strong>" }
            if underline { html = "<u>\(html)</u>" }
            if strike { html = "<del>\(html)</del>" }
            paragraphXHTML += html
            paragraphText += runText
            if !runText.trimmingCharacters(in: .whitespaces).isEmpty {
                paragraphAllBold = paragraphAllBold && bold
                paragraphMaxSize = max(paragraphMaxSize, runSize)
            }
            runText = ""
        }

        private func finishParagraph() {
            let plain = paragraphText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { return }
            switch DOCXConverter.headingLevel(styleName: styleName) {
            case 0?:
                if title == nil { title = plain } else { blocks.append(.heading(level: 1, text: plain)) }
            case let level?:
                blocks.append(.heading(level: level, text: plain))
            case nil where ProseHeuristics.isSceneBreak(plain):
                blocks.append(.sceneBreak)
            case nil:
                // 16 pt and up, or all bold, on a short single line at the very top.
                if blocks.isEmpty, title == nil, styledTitle == nil, plain.count <= 120, !plain.contains("\n"),
                   paragraphAllBold || paragraphMaxSize >= 32 {
                    styledTitle = plain
                }
                blocks.append(.paragraph(inline: paragraphXHTML.trimmingCharacters(in: .whitespaces)))
            }
        }
    }

    private final class StyleReader: NSObject, XMLParserDelegate {
        var names: [String: String] = [:]
        private var currentID: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "w:style" { currentID = attributes["w:styleId"] }
            if name == "w:name", let currentID, let value = attributes["w:val"] {
                names[currentID] = value.lowercased()
            }
        }
    }

    private final class CoreReader: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let key = name.split(separator: ":").last.map(String.init) ?? name
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["title", "creator", "description", "language"].contains(key), !value.isEmpty { values[key] = value }
            text = ""
        }
    }
}
