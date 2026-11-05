import Foundation

/// Converts Markdown books: headings, paragraphs, emphasis, links, lists,
/// block quotes, code and rules. A single leading `#` heading is the book's
/// title and `##` headings start chapters; otherwise each `#` starts one.
/// YAML front matter (`title:`, `author:`) fills in the metadata.
public struct MarkdownConverter: BookConverter {
    public init() {}

    public func document(from url: URL) async throws -> EPUBDocument {
        let text = try BookConverters.decodeText(BookConverters.readSource(url))
        return Self.document(fromMarkdown: text, fallbackTitle: BookConverters.title(for: url))
    }

    static func document(fromMarkdown text: String, fallbackTitle: String) -> EPUBDocument {
        let (front, body) = frontMatter(in: text)
        var blocks = Self.blocks(from: body)

        var title = front["title"]
        let topLevel = blocks.filter { if case .heading(1, _) = $0 { true } else { false } }.count
        if topLevel == 1, case .heading(1, let heading)? = blocks.first {
            title = title ?? heading
            blocks.removeFirst()
            blocks = blocks.map { if case .heading(let level, let text) = $0 { .heading(level: level - 1, text: text) } else { $0 } }
        }
        let levels = blocks.compactMap { if case .heading(let level, _) = $0 { level } else { nil } }
        let authors = (front["author"] ?? front["authors"]).map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } ?? []
        var document = EPUBDocument(
            title: title ?? fallbackTitle,
            authors: authors,
            chapters: TextBlock.chapters(from: blocks, splitLevel: levels.min())
        )
        if let language = front["lang"] ?? front["language"] ?? BookConverters.detectLanguage(body) {
            document.language = language
        }
        document.summary = front["description"] ?? front["summary"]
        return document
    }

    /// Splits off `---`-fenced YAML front matter and reads its simple `key: value` lines.
    static func frontMatter(in text: String) -> ([String: String], String) {
        guard text.hasPrefix("---\n") else { return ([:], text) }
        let rest = text.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") ?? rest.range(of: "\n...\n") else { return ([:], text) }
        var values: [String: String] = [:]
        for line in rest[..<end.lowerBound].split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { values[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = value }
        }
        return (values, String(rest[end.upperBound...]))
    }

    static func blocks(from text: String) -> [TextBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [TextBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inline: inline(paragraph.joined(separator: " "))))
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.raw("<pre><code>\(XHTML.escape(code.joined(separator: "\n")))</code></pre>"))
            } else if let heading = atxHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
            } else if !paragraph.isEmpty, paragraph.count == 1, let level = setextLevel(trimmed) {
                blocks.append(.heading(level: level, text: plain(paragraph[0])))
                paragraph = []
                index += 1
            } else if isRule(trimmed) {
                flushParagraph()
                blocks.append(.sceneBreak)
                index += 1
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                let paragraphs = quote.split(separator: "").map { "<p>\(inline($0.joined(separator: " ")))</p>" }
                blocks.append(.raw("<blockquote>\(paragraphs.joined())</blockquote>"))
            } else if case let (ordered, _)? = listItem(trimmed) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    if case let (isOrdered, text)? = listItem(current), isOrdered == ordered {
                        items.append(text)
                    } else if !current.isEmpty, !items.isEmpty, lines[index].first?.isWhitespace == true {
                        items[items.count - 1] += " " + current // continuation or nested line
                    } else {
                        break
                    }
                    index += 1
                }
                let tag = ordered ? "ol" : "ul"
                blocks.append(.raw("<\(tag)>\(items.map { "<li>\(inline($0))</li>" }.joined())</\(tag)>"))
            } else {
                paragraph.append(trimmed)
                index += 1
            }
        }
        flushParagraph()
        return blocks
    }

    static func atxHeading(_ line: String) -> TextBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: plain(text.trimmingCharacters(in: .whitespaces)))
    }

    static func setextLevel(_ line: String) -> Int? {
        if line.count >= 2, line.allSatisfy({ $0 == "=" }) { return 1 }
        if line.count >= 2, line.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    static func isRule(_ line: String) -> Bool {
        let chars = line.filter { !$0.isWhitespace }
        guard chars.count >= 3, let first = chars.first, "*-_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    /// `(ordered, text)` for "- item", "* item", "+ item" and "1. item".
    static func listItem(_ line: String) -> (Bool, String)? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            return (false, String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = line.dropFirst(digits.count)
            if let marker = rest.first, ".)".contains(marker), rest.dropFirst().first == " " {
                return (true, String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    /// Inline Markdown (emphasis, code, links) as escaped XHTML.
    static func inline(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else {
            return XHTML.escape(markdown)
        }
        var out = ""
        for run in attributed.runs {
            var text = XHTML.escape(String(attributed[run.range].characters))
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { text = "<code>\(text)</code>" }
            if intent.contains(.emphasized) { text = "<em>\(text)</em>" }
            if intent.contains(.stronglyEmphasized) { text = "<strong>\(text)</strong>" }
            if intent.contains(.strikethrough) { text = "<del>\(text)</del>" }
            if intent.contains(.lineBreak) { text = "<br/>" }
            if let link = run.link, ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                text = #"<a href="\#(XHTML.escape(link.absoluteString))">\#(text)</a>"#
            }
            out += text
        }
        return out
    }

    /// Heading text without Markdown markers.
    static func plain(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: markdown, options: options)).map { String($0.characters) } ?? markdown
    }
}
