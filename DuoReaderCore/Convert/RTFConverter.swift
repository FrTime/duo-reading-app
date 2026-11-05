import Foundation
import UIKit

/// Converts RTF books, keeping bold, italic, underline and strikethrough.
/// Paragraphs are lines; chapters are found the same way as in plain text.
/// The document's own title and author fields are used when present.
public struct RTFConverter: BookConverter {
    public init() {}

    public func document(from url: URL) async throws -> EPUBDocument {
        let data = try BookConverters.readSource(url)
        let string: NSAttributedString
        do {
            string = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        } catch {
            throw ConversionError.unreadable
        }
        let blocks = Self.blocks(from: string)
        let hasHeadings = blocks.contains { if case .heading = $0 { true } else { false } }
        // UIKit doesn't hand back RTF's \info fields, so read them from the source.
        let source = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        let title = Self.infoField("title", in: source)
        let author = Self.infoField("author", in: source)
        return EPUBDocument(
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? BookConverters.title(for: url),
            authors: author.flatMap { $0.isEmpty ? nil : [$0] } ?? [],
            chapters: TextBlock.chapters(from: blocks, splitLevel: hasHeadings ? 1 : nil)
        )
    }

    /// The text of `{\title …}` or `{\author …}` in the RTF header.
    static func infoField(_ name: String, in rtf: String) -> String? {
        guard let start = rtf.range(of: "{\\\(name) ") ?? rtf.range(of: "{\\\(name)\n"),
              let end = rtf[start.upperBound...].firstIndex(of: "}") else { return nil }
        let value = rtf[start.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.contains("\\") ? nil : value
    }

    static func blocks(from string: NSAttributedString) -> [TextBlock] {
        var blocks: [TextBlock] = []
        let text = string.string as NSString
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { line, range, _, _ in
            let plain = (line ?? "").trimmingCharacters(in: .whitespaces)
            if plain.isEmpty { return }
            if ProseHeuristics.isSceneBreak(plain) {
                blocks.append(.sceneBreak)
            } else if ProseHeuristics.isChapterHeading(plain) {
                blocks.append(.heading(level: 1, text: plain))
            } else {
                blocks.append(.paragraph(inline: inline(string.attributedSubstring(from: range)).trimmingCharacters(in: .whitespaces)))
            }
        }
        return blocks
    }

    /// One paragraph's runs as escaped XHTML with formatting tags.
    static func inline(_ string: NSAttributedString) -> String {
        var out = ""
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            var text = XHTML.escape((string.string as NSString).substring(with: range))
            let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            if traits.contains(.traitItalic) { text = "<em>\(text)</em>" }
            if traits.contains(.traitBold) { text = "<strong>\(text)</strong>" }
            if (attributes[.underlineStyle] as? Int ?? 0) != 0 { text = "<u>\(text)</u>" }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { text = "<del>\(text)</del>" }
            out += text
        }
        return out
    }
}
