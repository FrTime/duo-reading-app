import Foundation
import SwiftData
import Testing
@testable import DuoReader

struct FB2ConverterTests {
    static let coverBase64 = Fixtures.tinyPNG.base64EncodedString()

    static let book = """
    <?xml version="1.0" encoding="UTF-8"?>
    <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
      <description>
        <title-info>
          <genre>sf</genre>
          <author><first-name>Ada</first-name><last-name>Writer</last-name></author>
          <author><nickname>bo2</nickname></author>
          <book-title>The Long Road</book-title>
          <annotation><p>A journey.</p></annotation>
          <coverpage><image l:href="#cover.png"/></coverpage>
          <lang>en</lang>
        </title-info>
      </description>
      <body>
        <title><p>The Long Road</p></title>
        <section>
          <title><p>Chapter 1</p><p>Departure</p></title>
          <epigraph><p>All roads lead somewhere.</p></epigraph>
          <p>It was <emphasis>dark</emphasis> &amp; <strong>stormy</strong>.</p>
          <empty-line/>
          <subtitle>* * *</subtitle>
          <section><title><p>Part A</p></title><p>Nested text.</p></section>
          <poem><stanza><v>Roses are red</v><v>Violets are blue</v></stanza></poem>
        </section>
        <section>
          <title><p>Chapter 2</p></title>
          <p>Arrival.</p>
        </section>
      </body>
      <body name="notes"><section><p>Note one.</p></section></body>
      <binary id="cover.png" content-type="image/png">\(coverBase64)</binary>
    </FictionBook>
    """

    @Test func sectionsBecomeChaptersWithMetadataAndCover() throws {
        let doc = try #require(FB2Converter.document(fromFB2: Data(Self.book.utf8), fallbackTitle: "file"))
        #expect(doc.title == "The Long Road")
        #expect(doc.authors == ["Ada Writer", "bo2"])
        #expect(doc.summary == "A journey.")
        #expect(doc.language == "en")
        #expect(doc.coverImage == Fixtures.tinyPNG)
        #expect(doc.chapters.map(\.title) == ["Chapter 1 Departure", "Chapter 2", "Notes"])

        let one = doc.chapters[0].body
        #expect(one.contains("<blockquote><p>All roads lead somewhere.</p></blockquote>"))
        #expect(one.contains("<p>It was <em>dark</em> &amp; <strong>stormy</strong>.</p>"))
        #expect(one.contains(#"<hr class="scene-break"/>"#))
        #expect(one.contains("<h3>Part A</h3>"))
        #expect(one.contains(#"<p class="verse">Roses are red</p>"#))
        #expect(doc.chapters[2].body.contains("Note one."))
    }

    @Test func honoursADeclaredLegacyEncoding() throws {
        let xml = #"<?xml version="1.0" encoding="windows-1251"?><FictionBook><description><title-info><book-title>"#
        let tail = "</book-title></title-info></description><body><section><p>x</p></section></body></FictionBook>"
        // "Книга" in windows-1251.
        let data = Data(xml.utf8) + Data([0xCA, 0xED, 0xE8, 0xE3, 0xE0]) + Data(tail.utf8)
        #expect(FB2Converter.document(fromFB2: data, fallbackTitle: "f")?.title == "Книга")
    }

    @Test func rejectsXMLThatIsNotFictionBook() {
        #expect(FB2Converter.document(fromFB2: Data("<html><body/></html>".utf8), fallbackTitle: "f") == nil)
        #expect(FB2Converter.document(fromFB2: Data("not xml".utf8), fallbackTitle: "f") == nil)
    }

    @Test func coverSurvivesTheTripThroughEPUB() async throws {
        let doc = try #require(FB2Converter.document(fromFB2: Data(Self.book.utf8), fallbackTitle: "file"))
        let url = Fixtures.temporaryURL("fb2.epub")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await EPUBWriter.write(doc, to: url)
        let metadata = try await EPUBMetadataReader().readMetadata(from: url)
        #expect(metadata.coverImageData == Fixtures.tinyPNG)
        #expect(metadata.authors == ["Ada Writer", "bo2"])
    }
}

struct DOCXConverterTests {
    static let documentXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p><w:pPr><w:pStyle w:val="Titel"/></w:pPr><w:r><w:t>Body Title</w:t></w:r></w:p>
        <w:p><w:r><w:t>Front matter.</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="berschrift1"/></w:pPr><w:r><w:t>One</w:t></w:r></w:p>
        <w:p><w:r><w:t xml:space="preserve">Plain </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>bold</w:t></w:r><w:r><w:t xml:space="preserve"> and </w:t></w:r><w:r><w:rPr><w:i/><w:b w:val="0"/></w:rPr><w:t>italic &lt;x&gt;</w:t></w:r><w:r><w:br/><w:t>next line</w:t></w:r></w:p>
        <w:p><w:r><w:t>* * *</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="berschrift2"/></w:pPr><w:r><w:t>Sub</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="berschrift1"/></w:pPr><w:r><w:t>Two</w:t></w:r></w:p>
        <w:p><w:r><w:t>End.</w:t></w:r><w:r><w:br w:type="page"/></w:r></w:p>
        <w:sectPr/>
      </w:body>
    </w:document>
    """

    static let stylesXML = """
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:style w:type="paragraph" w:styleId="Titel"><w:name w:val="Title"/></w:style>
      <w:style w:type="paragraph" w:styleId="berschrift1"><w:name w:val="heading 1"/></w:style>
      <w:style w:type="paragraph" w:styleId="berschrift2"><w:name w:val="heading 2"/></w:style>
    </w:styles>
    """

    static func coreXML(title: String?) -> String {
        """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
            xmlns:dc="http://purl.org/dc/elements/1.1/">
          \(title.map { "<dc:title>\($0)</dc:title>" } ?? "")<dc:creator>Ada Writer; Bo Second</dc:creator>
        </cp:coreProperties>
        """
    }

    static func sample(title: String? = "Properties Title", name: String = "doc.docx") async throws -> URL {
        try await ComicConverterTests.zip([
            ("word/document.xml", Data(documentXML.utf8)),
            ("word/styles.xml", Data(stylesXML.utf8)),
            ("docProps/core.xml", Data(coreXML(title: title).utf8)),
        ], name: name)
    }

    @Test func headingStylesSplitChaptersAndFormattingIsKept() async throws {
        let doc = try await DOCXConverter().document(from: try await Self.sample())
        #expect(doc.title == "Properties Title")
        #expect(doc.authors == ["Ada Writer", "Bo Second"])
        #expect(doc.chapters.map(\.title) == [nil, "One", "Two"])

        let one = doc.chapters[1].body
        #expect(one.contains("<p>Plain <strong>bold</strong> and <em>italic &lt;x&gt;</em><br/>next line</p>"))
        #expect(one.contains(#"<hr class="scene-break"/>"#))
        #expect(one.contains("<h3>Sub</h3>"))
        #expect(!doc.chapters.map(\.body).joined().contains("Body Title"))
    }

    @Test func titleStyleIsTheFallbackTitle() async throws {
        let doc = try await DOCXConverter().document(from: try await Self.sample(title: nil))
        #expect(doc.title == "Body Title")
    }

    @Test func aLeadingHeadingTitlesADocumentWithNoTitle() {
        let parsed = DOCXConverter.blocks(fromDocument: Data(Self.documentXML.utf8), styleNames: [:])
        #expect(DOCXConverter.leadingHeading([.heading(level: 1, text: "Garden Plans"), .paragraph(inline: "x")]) == "Garden Plans")
        #expect(DOCXConverter.leadingHeading([.paragraph(inline: "x"), .heading(level: 1, text: "Later")]) == nil)
        #expect(!parsed.blocks.isEmpty)
    }

    @Test func textBoxesKeepTheSurroundingTextAndAreNotDoubled() async throws {
        let body = """
        <w:document xmlns:w="w" xmlns:mc="mc" xmlns:wps="wps" xmlns:v="v"><w:body>
          <w:p><w:r><w:t xml:space="preserve">Before </w:t></w:r><w:r><mc:AlternateContent>
            <mc:Choice><w:drawing><wps:txbx><w:txbxContent><w:p><w:r><w:t>Boxed</w:t></w:r></w:p></w:txbxContent></wps:txbx></w:drawing></mc:Choice>
            <mc:Fallback><w:pict><v:textbox><w:txbxContent><w:p><w:r><w:t>Boxed</w:t></w:r></w:p></w:txbxContent></v:textbox></w:pict></mc:Fallback>
          </mc:AlternateContent></w:r><w:r><w:t xml:space="preserve"> after.</w:t></w:r></w:p>
        </w:body></w:document>
        """
        let parsed = DOCXConverter.blocks(fromDocument: Data(body.utf8), styleNames: [:])
        #expect(parsed.blocks.count == 1)
        guard case .paragraph(let inline)? = parsed.blocks.first else { Issue.record("\(parsed.blocks)"); return }
        #expect(inline.contains("Before"))
        #expect(inline.contains("after."))
        #expect(inline.components(separatedBy: "Boxed").count == 2)
    }

    @Test func notADocxIsUnreadable() async throws {
        let zip = try await ComicConverterTests.zip([("readme.txt", Data("x".utf8))], name: "fake.docx")
        await #expect(throws: ConversionError.unreadable) { _ = try await DOCXConverter().document(from: zip) }
    }

    @Test func wellFormedOutput() async throws {
        let doc = try await DOCXConverter().document(from: try await Self.sample())
        for (path, data) in EPUBWriter.files(for: doc) where path.hasSuffix(".xhtml") {
            #expect(XMLParser(data: data).parse(), "\(path) isn't well-formed")
        }
    }
}

@MainActor
struct FB2DOCXImportTests {
    @Test func importsBothFormats() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let importer = LibraryImporter(modelContainer: container, booksFolder: Fixtures.temporaryURL("Books"))
        let fb2 = Fixtures.temporaryURL("road.fb2")
        try FileManager.default.createDirectory(at: fb2.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(FB2ConverterTests.book.utf8).write(to: fb2)

        #expect(await importer.importFile(fb2).isImported)
        #expect(await importer.importFile(try await DOCXConverterTests.sample()).isImported)
        let books = try container.mainContext.fetch(FetchDescriptor<Book>(sortBy: [SortDescriptor(\.shelfOrder)]))
        #expect(books.map(\.title) == ["The Long Road", "Properties Title"])
        #expect(books.allSatisfy { $0.format == .epub })
        #expect(books[0].coverImageData != nil)
        #expect(Set(LibraryImporter.supportedFormats).isSuperset(of: [.fb2, .docx]))
    }
}

private extension ImportOutcome {
    var isImported: Bool {
        if case .imported = self { true } else { false }
    }
}
