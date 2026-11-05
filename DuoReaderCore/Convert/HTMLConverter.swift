import Foundation
import SwiftSoup

/// Converts HTML books, including Archive of Our Own's HTML downloads.
///
/// The HTML is cleaned to a safe set of tags (no scripts, styles, forms,
/// frames, images or event handlers), re-serialised as XHTML, and split into
/// chapters at headings. For AO3 downloads, each AO3 chapter becomes a
/// chapter, and the preface page is kept first, so the same AO3 tag parsing
/// as for AO3's EPUBs fills in fandoms, ships and tags.
public struct HTMLConverter: BookConverter {
    public init() {}

    public func document(from url: URL) async throws -> EPUBDocument {
        let html = try BookConverters.decodeText(BookConverters.readSource(url, limit: BookConverters.maxHTMLBytes))
        do {
            return try Self.document(fromHTML: html, fallbackTitle: BookConverters.title(for: url))
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.unreadable
        }
    }

    static func document(fromHTML html: String, fallbackTitle: String) throws -> EPUBDocument {
        let page = try SwiftSoup.parse(html)
        guard let body = page.body() else { throw ConversionError.unreadable }
        if let ao3 = try ao3Document(page, body: body) { return ao3 }

        // Clean once, then split the safe XHTML at its headings.
        let safe = try xhtmlFragment(body.html())
        var blocks = try Self.blocks(in: Self.contentRoot(of: safe.body() ?? body))
        var title = try nonEmpty(page.title())
        let topLevel = blocks.filter { if case .heading(1, _) = $0 { true } else { false } }.count
        if topLevel == 1, case .heading(1, let heading)? = blocks.first {
            title = title ?? heading
            blocks.removeFirst()
            blocks = blocks.map { if case .heading(let level, let text) = $0 { .heading(level: level - 1, text: text) } else { $0 } }
        }
        let levels = blocks.compactMap { if case .heading(let level, _) = $0 { level } else { nil } }
        var document = EPUBDocument(
            title: title ?? fallbackTitle,
            authors: try page.select("meta[name=author]").array().compactMap { try nonEmpty($0.attr("content")) },
            chapters: TextBlock.chapters(from: blocks, splitLevel: levels.min())
        )
        document.summary = try nonEmpty(page.select("meta[name=description]").first()?.attr("content") ?? "")
        document.language = try languageCode(page) ?? BookConverters.detectLanguage(body.text()) ?? "en"
        return document
    }

    // MARK: - AO3

    /// AO3 downloads have `#preface`, `#chapters` and `#afterword` sections
    /// and say where the work was posted.
    static func ao3Document(_ page: Document, body: Element) throws -> EPUBDocument? {
        guard let chapters = try body.select("#chapters").first() else { return nil }
        let workLink = try body.select("a[href*=archiveofourown.org/works/]").first()?.attr("href")
        let mentionsAO3 = try body.select("#preface").text().localizedCaseInsensitiveContains("Archive of Our Own")
        guard workLink != nil || mentionsAO3 else { return nil }

        let preface = try body.select("#preface").first()
        let title = try nonEmpty(preface?.select("h1").first()?.text() ?? "")
            ?? nonEmpty(page.title())
            ?? String(localized: "Untitled")
        var document = EPUBDocument(
            title: title,
            authors: try body.select("#preface a[rel=author]").array().compactMap { try nonEmpty($0.text()) },
            chapters: []
        )
        document.publisher = "Archive of Our Own"
        document.sourceIdentifiers = workLink.map { [$0] } ?? []
        document.summary = try nonEmpty(preface?.select("blockquote.userstuff").first()?.text() ?? "")
        document.language = try languageCode(page) ?? BookConverters.detectLanguage(chapters.text()) ?? "en"

        if let preface {
            document.chapters.append(.init(title: nil, body: try clean(preface.html())))
        }
        document.chapters += try ao3Chapters(in: chapters)
        if let afterword = try body.select("#afterword").first(), try !afterword.text().isEmpty {
            document.chapters.append(.init(title: String(localized: "Afterword"), body: try clean(afterword.html())))
        }
        return document
    }

    /// Each AO3 chapter starts with a heading (`h2.heading` or
    /// `h2.toc-heading`, often inside a `div.meta`). A one-shot has none.
    static func ao3Chapters(in container: Element) throws -> [EPUBDocument.Chapter] {
        var chapters: [EPUBDocument.Chapter] = []
        var title: String?
        var html = ""
        func flush() {
            let hasText = !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if title != nil || hasText { chapters.append(.init(title: title, body: html)) }
            title = nil
            html = ""
        }
        for node in container.getChildNodes() {
            if let element = node as? Element,
               let heading = try startsAO3Chapter(element) {
                flush()
                title = heading
                html = "<h2>\(XHTML.escape(heading))</h2>\n"
                // Chapter notes live in the same meta block, after the heading.
                if element.tagName() != "h2" {
                    try element.select("h2.heading, h2.toc-heading").remove()
                    html += try clean(element.outerHtml())
                }
            } else {
                html += try clean(node.outerHtml())
            }
        }
        flush()
        return chapters.isEmpty ? [.init(title: nil, body: try clean(container.html()))] : chapters
    }

    private static func startsAO3Chapter(_ element: Element) throws -> String? {
        if element.tagName() == "h2", element.hasClass("heading") || element.hasClass("toc-heading") {
            return try nonEmpty(element.text())
        }
        if element.hasClass("meta"), let heading = try element.select("h2.heading, h2.toc-heading").first() {
            return try nonEmpty(heading.text())
        }
        return nil
    }

    // MARK: - Generic HTML

    /// Unwraps single wrapper elements (`<div id="content"><article>…`) so
    /// headings sit at the top level and can split chapters.
    static func contentRoot(of body: Element) -> Element {
        var root = body
        while root.children().size() == 1,
              let only = root.children().first(),
              ["div", "main", "article", "section"].contains(only.tagName()),
              root.textNodes().allSatisfy({ $0.isBlank() }) {
            root = only
        }
        return root
    }

    static func blocks(in root: Element) throws -> [TextBlock] {
        var blocks: [TextBlock] = []
        for node in root.getChildNodes() {
            if let element = node as? Element,
               let level = ["h1", "h2", "h3"].firstIndex(of: element.tagName()).map({ $0 + 1 }),
               let text = try nonEmpty(element.text()) {
                blocks.append(.heading(level: level, text: text))
            } else if let text = node as? TextNode {
                if !text.isBlank() { blocks.append(.paragraph(inline: XHTML.escape(text.text().trimmingCharacters(in: .whitespacesAndNewlines)))) }
            } else {
                let xhtml = try node.outerHtml()
                if !xhtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.raw(xhtml)) }
            }
        }
        return blocks
    }

    // MARK: - Cleaning

    /// Keeps a safe, book-shaped subset of HTML and serialises it as XHTML.
    static func clean(_ html: String) throws -> String {
        try xhtmlFragment(html).body()?.html() ?? ""
    }

    /// `html` cleaned to the allowed tags, as a document that prints XHTML.
    static func xhtmlFragment(_ html: String) throws -> Document {
        let allowed = try Whitelist.relaxed()
            .addTags("hr", "section", "del", "s", "abbr", "center", "figure", "figcaption")
            .removeTags("img", "col", "colgroup")
        let fragment = try SwiftSoup.parseBodyFragment(SwiftSoup.clean(html, allowed) ?? "")
        fragment.outputSettings()
            .syntax(syntax: .xml)
            .escapeMode(Entities.EscapeMode.xhtml)
            .charset(.utf8)
            .prettyPrint(pretty: false)
        return fragment
    }

    private static func languageCode(_ page: Document) throws -> String? {
        let lang = try page.select("html").first()?.attr("lang") ?? ""
        return lang.isEmpty ? nil : lang
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
