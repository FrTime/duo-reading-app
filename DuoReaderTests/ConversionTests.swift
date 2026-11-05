import Foundation
import SwiftData
import Testing
import UIKit
@testable import DuoReader

struct XHTMLEscapeTests {
    @Test func escapesMarkupAndDropsControlCharacters() {
        #expect(XHTML.escape(#"Tom & "Jerry" <3"#) == "Tom &amp; &quot;Jerry&quot; &lt;3")
        #expect(XHTML.escape("a\u{0}b\u{1B}c\td") == "abc\td")
    }
}

struct ProseHeuristicsTests {
    @Test(arguments: ["Chapter 1", "CHAPTER TWELVE", "Chapter 3: The Storm", "Part One", "Prologue",
                      "Epilogue", "Book IV", "chapter xii. Home", "Interlude"])
    func recognisesChapterHeadings(_ line: String) {
        #expect(ProseHeuristics.isChapterHeading(line))
    }

    @Test(arguments: ["Part of the problem was the rain.", "Chapter and verse, she said,",
                      "The chapter ended.", "", "Booking a table"])
    func ignoresOrdinaryLines(_ line: String) {
        #expect(!ProseHeuristics.isChapterHeading(line))
    }

    @Test(arguments: ["***", "* * *", "#", "~~~", "———", "-o-", "x-x-x"])
    func recognisesSceneBreaks(_ line: String) {
        #expect(ProseHeuristics.isSceneBreak(line))
    }

    @Test(arguments: ["ox", "Hello", "1990"])
    func ignoresNonBreaks(_ line: String) {
        #expect(!ProseHeuristics.isSceneBreak(line))
    }
}

struct PlainTextConverterTests {
    @Test func joinsHardWrappedLinesAndSplitsChapters() {
        let text = """
        Title: The Long Road
        Author: Ada Writer
        Language: English

        Chapter 1

        It was a dark
        and stormy night.

        She <waited> & watched.

        * * *

        Chapter 2: Morning

        Dawn came.
        """
        let doc = PlainTextConverter.document(fromText: text, fallbackTitle: "file")
        #expect(doc.title == "The Long Road")
        #expect(doc.authors == ["Ada Writer"])
        #expect(doc.language == "en")
        #expect(doc.chapters.map(\.title) == [nil, "Chapter 1", "Chapter 2: Morning"])
        let first = doc.chapters[1].body
        #expect(first.contains("<p>It was a dark and stormy night.</p>"))
        #expect(first.contains("<p>She &lt;waited&gt; &amp; watched.</p>"))
        #expect(first.contains(#"<hr class="scene-break"/>"#))
    }

    @Test func oneParagraphPerLineWhenThereAreNoBlankLines() {
        let blocks = PlainTextConverter.blocks(from: "First line.\nSecond line.\nThird line.")
        #expect(blocks == [.paragraph(inline: "First line."), .paragraph(inline: "Second line."), .paragraph(inline: "Third line.")])
    }

    @Test func detectsTheLanguageWhenTheFileDoesNotSayIt() {
        let french = "Il était une fois une petite fille qui vivait au bord de la mer avec sa grand-mère. Chaque matin, elle descendait sur la plage pour regarder les bateaux partir."
        #expect(PlainTextConverter.document(fromText: french, fallbackTitle: "conte").language == "fr")
        #expect(BookConverters.detectLanguage("ok") == nil)
    }

    @Test func usesTheFileNameWithoutAHeader() {
        let doc = PlainTextConverter.document(fromText: "Just a story.", fallbackTitle: "my story")
        #expect(doc.title == "my story")
        #expect(doc.chapters.count == 1)
    }

    @Test func decodesUTF8WithBOMAndWindows1252() throws {
        #expect(try BookConverters.decodeText(Data([0xEF, 0xBB, 0xBF]) + Data("café\r\nok".utf8)) == "café\nok")
        #expect(try BookConverters.decodeText(Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x93, 0x94])) == "café \u{201C}\u{201D}")
    }

    @Test func rejectsBinaryFiles() {
        #expect(throws: ConversionError.unreadable) {
            try BookConverters.decodeText(Data(repeating: 0, count: 64) + Data("abc".utf8))
        }
    }

    @Test func splitsLongBooksWithoutHeadingsIntoParts() {
        let blocks = Array(repeating: TextBlock.paragraph(inline: String(repeating: "word ", count: 200)), count: 300)
        let chapters = TextBlock.chapters(from: blocks, splitLevel: nil, maxChapterBytes: 50_000)
        #expect(chapters.count > 1)
        #expect(chapters.allSatisfy { $0.title == nil && $0.body.utf8.count < 52_000 })
    }
}

struct MarkdownConverterTests {
    @Test func singleTopHeadingIsTheTitleAndSecondLevelHeadingsAreChapters() {
        let markdown = """
        ---
        author: Ada Writer, Bo Second
        ---
        # The Book

        Opening words.

        ## One

        Some *soft* and **strong** text with `code` and a [link](https://example.com).

        ### A scene

        - first
        - second

        ## Two

        > quoted line

        ```
        let x = 1 < 2
        ```
        """
        let doc = MarkdownConverter.document(fromMarkdown: markdown, fallbackTitle: "file")
        #expect(doc.title == "The Book")
        #expect(doc.authors == ["Ada Writer", "Bo Second"])
        #expect(doc.chapters.map(\.title) == [nil, "One", "Two"])
        let one = doc.chapters[1].body
        #expect(one.contains("<em>soft</em>"))
        #expect(one.contains("<strong>strong</strong>"))
        #expect(one.contains("<code>code</code>"))
        #expect(one.contains(#"<a href="https://example.com">link</a>"#))
        #expect(one.contains("<h3>A scene</h3>"))
        #expect(one.contains("<ul><li>first</li><li>second</li></ul>"))
        let two = doc.chapters[2].body
        #expect(two.contains("<blockquote><p>quoted line</p></blockquote>"))
        #expect(two.contains("<pre><code>let x = 1 &lt; 2</code></pre>"))
    }

    @Test func dropsScriptLinksButKeepsTheirText() {
        #expect(MarkdownConverter.inline("[click](javascript:alert(1))") == "click")
    }

    @Test func everyTopHeadingStartsAChapterWhenThereAreSeveral() {
        let doc = MarkdownConverter.document(fromMarkdown: "# A\n\ntext\n\n# B\n\nmore", fallbackTitle: "notes")
        #expect(doc.title == "notes")
        #expect(doc.chapters.map(\.title) == ["A", "B"])
    }

    @Test func rulesAreSceneBreaksAndSetextHeadingsWork() {
        let blocks = MarkdownConverter.blocks(from: "Title\n=====\n\ntext\n\n---\n\nOrdered:\n\n1. a\n2. b")
        #expect(blocks.first == .heading(level: 1, text: "Title"))
        #expect(blocks.contains(.sceneBreak))
        #expect(blocks.last == .raw("<ol><li>a</li><li>b</li></ol>"))
    }
}

struct RTFConverterTests {
    @Test func keepsFormattingAndReadsInfo() async throws {
        let rtf = #"""
        {\rtf1\ansi{\fonttbl\f0 Helvetica;}{\info{\title Rich Story}{\author Ada Writer}}
        \f0 Chapter 1\par
        Plain and {\b bold} and {\i italic} & more.\par
        }
        """#
        let url = Fixtures.temporaryURL("story.rtf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(rtf.utf8).write(to: url)

        let doc = try await RTFConverter().document(from: url)
        #expect(doc.title == "Rich Story")
        #expect(doc.authors == ["Ada Writer"])
        #expect(doc.chapters.map(\.title) == ["Chapter 1"])
        let body = doc.chapters[0].body
        #expect(body.contains("<strong>bold</strong>"))
        #expect(body.contains("<em>italic</em>"))
        #expect(body.contains("&amp; more."))
    }
}

struct EPUBWriterTests {
    let document: EPUBDocument = {
        var doc = EPUBDocument(title: "Tom & Jerry", authors: ["Ada Writer"], chapters: [
            .init(title: nil, body: "<p>Front</p>"),
            .init(title: "One <1>", body: "<h2>One &lt;1&gt;</h2><p>Text</p>"),
        ])
        doc.summary = "A short, sweet summary"
        return doc
    }()

    @Test func roundTripsThroughTheEPUBReader() async throws {
        let url = Fixtures.temporaryURL("out.epub")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await EPUBWriter.write(document, to: url)

        let metadata = try await EPUBMetadataReader().readMetadata(from: url)
        #expect(metadata.title == "Tom & Jerry")
        #expect(metadata.authors == ["Ada Writer"])
        #expect(metadata.summary == "A short, sweet summary")
    }

    @Test func everyXMLFileIsWellFormed() {
        for (path, data) in EPUBWriter.files(for: document) where path.hasSuffix(".xhtml") || path.hasSuffix(".opf") || path.hasSuffix(".xml") {
            let parser = XMLParser(data: data)
            #expect(parser.parse(), "\(path) isn't well-formed: \(parser.parserError.map { "\($0)" } ?? "")")
        }
    }

    @Test func mimetypeComesFirstAndNavListsTheStart() throws {
        let files = EPUBWriter.files(for: document)
        #expect(files.first?.0 == "mimetype")
        let nav = String(decoding: try #require(files.first { $0.0 == "OEBPS/nav.xhtml" }).1, as: UTF8.self)
        #expect(nav.contains(#"<a href="text/chapter-001.xhtml">Tom &amp; Jerry</a>"#))
        #expect(nav.contains(#"<a href="text/chapter-002.xhtml">One &lt;1&gt;</a>"#))
    }
}

@MainActor
struct TextImportTests {
    let container: ModelContainer
    let booksFolder: URL
    let importer: LibraryImporter

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        booksFolder = Fixtures.temporaryURL("Books")
        importer = LibraryImporter(modelContainer: container, booksFolder: booksFolder)
    }

    private func write(_ text: String, as name: String) throws -> URL {
        let url = Fixtures.temporaryURL(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func importsATextFileAsAnEPUB() async throws {
        let url = try write("Title: Plain Tale\nAuthor: Ada Writer\n\nChapter 1\n\nOnce.", as: "plain_tale.txt")
        let outcome = await importer.importFile(url)
        guard case .imported(_, let title) = outcome else {
            Issue.record("Expected import, got \(outcome)"); return
        }
        #expect(title == "Plain Tale")

        let book = try #require(try container.mainContext.fetch(FetchDescriptor<Book>()).first)
        #expect(book.format == .epub)
        #expect(book.authors == ["Ada Writer"])
        #expect(book.relativeFilePath == "\(book.id.uuidString).epub")
        let copy = booksFolder.appending(path: book.relativeFilePath)
        #expect(try await EPUBMetadataReader().readMetadata(from: copy).title == "Plain Tale")
    }

    @Test func reimportingTheSameTextIsADuplicate() async throws {
        let url = try write("A small story.", as: "small.md")
        _ = await importer.importFile(url)
        #expect(await importer.importFile(url) == .duplicate(title: "small"))
    }

    @Test func binaryTextFilesFailCleanly() async throws {
        let url = Fixtures.temporaryURL("junk.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 256).write(to: url)
        #expect(await importer.importFile(url) == .failed(fileName: "junk.txt", reason: .unreadable))
        #expect(try container.mainContext.fetch(FetchDescriptor<Book>()).isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: booksFolder.path()))?.isEmpty ?? true)
    }

    @Test func oversizedTextFilesSayWhy() async throws {
        let url = Fixtures.temporaryURL("huge.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path(), contents: nil)
        // A sparse file: reports the size without writing 50 MB.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(BookConverters.maxSourceBytes + 1))
        try handle.close()
        #expect(await importer.importFile(url) == .failed(fileName: "huge.txt", reason: .tooLarge))
    }

    @Test func textFormatsAreOffered() {
        #expect(Set(LibraryImporter.supportedFormats).isSuperset(of: [.epub, .pdf, .txt, .markdown, .rtf]))
    }
}
