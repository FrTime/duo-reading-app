import Foundation
import Testing
@testable import DuoReader

struct EPUBMetadataReaderTests {
    let reader = EPUBMetadataReader()

    // MARK: EPUB 3

    @Test func readsEPUB3Metadata() async throws {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">urn:isbn:9780000000001</dc:identifier>
            <dc:title>The Long Way Round</dc:title>
            <dc:creator>Ada Writer</dc:creator>
            <dc:creator>Ben Coauthor</dc:creator>
            <dc:language>en</dc:language>
            <dc:publisher>Small Press</dc:publisher>
            <dc:description>&lt;p&gt;A story &amp;amp; more.&lt;/p&gt;</dc:description>
            <dc:subject>Fantasy</dc:subject>
            <dc:subject>Fantasy</dc:subject>
            <meta property="belongs-to-collection" id="c1">The Round Books</meta>
            <meta refines="#c1" property="group-position">2</meta>
          </metadata>
          <manifest>
            <item id="img" href="images/front.png" media-type="image/png" properties="cover-image"/>
            <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="ch1"/></spine>
        </package>
        """
        let url = try await Fixtures.epub([
            "OEBPS/content.opf": Data(opf.utf8),
            "OEBPS/images/front.png": Fixtures.tinyPNG,
            "OEBPS/text/ch1.xhtml": Data("<html/>".utf8),
        ])

        let m = try await reader.readMetadata(from: url)
        #expect(m.title == "The Long Way Round")
        #expect(m.authors == ["Ada Writer", "Ben Coauthor"])
        #expect(m.language == "en")
        #expect(m.publisher == "Small Press")
        #expect(m.summary == "A story & more.")
        #expect(m.subjects == ["Fantasy"])
        #expect(m.series == "The Round Books")
        #expect(m.seriesIndex == 2)
        #expect(m.identifiers == ["urn:isbn:9780000000001"])
        #expect(m.coverImageData == Fixtures.tinyPNG)
        #expect(m.ao3 == nil)
    }

    // MARK: EPUB 2

    @Test func readsEPUB2CoverAndCalibreSeries() async throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:title>Old Style</dc:title>
            <meta name="cover" content="cover-img"/>
            <meta name="calibre:series" content="Classics"/>
            <meta name="calibre:series_index" content="3.5"/>
          </metadata>
          <manifest>
            <item id="cover-img" href="../Images/c%20over.png" media-type="image/png"/>
          </manifest>
          <spine/>
        </package>
        """
        let url = try await Fixtures.epub([
            "OPS/Text/content.opf": Data(opf.utf8),
            "OPS/Images/c over.png": Fixtures.tinyPNG,
        ], opfPath: "OPS/Text/content.opf")

        let m = try await reader.readMetadata(from: url)
        #expect(m.title == "Old Style")
        #expect(m.series == "Classics")
        #expect(m.seriesIndex == 3.5)
        #expect(m.coverImageData == Fixtures.tinyPNG)
        #expect(m.authors.isEmpty)
    }

    @Test func fallsBackToImageNamedCover() async throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
          <manifest><item id="i1" href="cover.png" media-type="image/png"/></manifest>
          <spine/>
        </package>
        """
        let url = try await Fixtures.epub(["content.opf": Data(opf.utf8), "cover.png": Fixtures.tinyPNG], opfPath: "content.opf")
        #expect(try await reader.readMetadata(from: url).coverImageData == Fixtures.tinyPNG)
    }

    // MARK: AO3

    @Test func readsAO3Tags() async throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>A Fic Title</dc:title>
            <dc:creator>someauthor</dc:creator>
            <dc:publisher>Archive of Our Own</dc:publisher>
            <dc:identifier>https://archiveofourown.org/works/123456</dc:identifier>
            <dc:subject>Fanworks</dc:subject>
          </metadata>
          <manifest>
            <item id="preface" href="preface.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="preface"/></spine>
        </package>
        """
        let preface = """
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <div class="meta"><dl class="tags">
          <dt>Rating:</dt>
          <dd><a href="https://archiveofourown.org/tags/Teen">Teen And Up Audiences</a></dd>
          <dt>Archive Warning:</dt>
          <dd><a href="#">No Archive Warnings Apply</a></dd>
          <dt>Category:</dt>
          <dd><a href="#">F/M</a>, <a href="#">Gen</a></dd>
          <dt>Fandom:</dt>
          <dd><a href="#">Some Fandom</a>, <a href="#">Other Fandom &amp; Co</a></dd>
          <dt>Relationship:</dt>
          <dd><a href="#">A/B</a></dd>
          <dt>Characters:</dt>
          <dd><a href="#">A</a>, <a href="#">B</a>, <a href="#">C</a></dd>
          <dt>Additional Tags:</dt>
          <dd><a href="#">Slow Burn</a>, <a href="#">Foreshadowing</a></dd>
          <dt>Series:</dt>
          <dd>Part 2 of <a href="#">The Saga</a></dd>
          <dt>Stats:</dt>
          <dd>Published: 2024-01-01 Words: 123,456 Chapters: 12/?</dd>
        </dl></div>
        </body></html>
        """
        let url = try await Fixtures.epub([
            "OEBPS/content.opf": Data(opf.utf8),
            "OEBPS/preface.xhtml": Data(preface.utf8),
        ])

        let m = try await reader.readMetadata(from: url)
        let ao3 = try #require(m.ao3)
        #expect(ao3.workURL == URL(string: "https://archiveofourown.org/works/123456"))
        #expect(ao3.rating == "Teen And Up Audiences")
        #expect(ao3.warnings == ["No Archive Warnings Apply"])
        #expect(ao3.categories == ["F/M", "Gen"])
        #expect(ao3.fandoms == ["Some Fandom", "Other Fandom & Co"])
        #expect(ao3.relationships == ["A/B"])
        #expect(ao3.characters == ["A", "B", "C"])
        #expect(ao3.additionalTags == ["Slow Burn", "Foreshadowing"])
        #expect(ao3.wordCount == 123_456)
        #expect(ao3.chapters == "12/?")
        #expect(m.series == "The Saga")
        #expect(m.seriesIndex == 2)
    }

    // MARK: Errors

    @Test func rejectsNonZip() async throws {
        let url = Fixtures.temporaryURL("bad.epub")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a zip".utf8).write(to: url)
        #expect(throws: MetadataError.self) { try await reader.readMetadata(from: url) }
    }

    @Test func rejectsMissingPackage() async throws {
        let url = try await Fixtures.epub(["OEBPS/other.txt": Data("x".utf8)])
        #expect(throws: MetadataError.malformed("Missing package document")) { try await reader.readMetadata(from: url) }
    }

    @Test func rejectsOversizedPackageDocument() async throws {
        let huge = Data(repeating: 0x20, count: Int(EPUBMetadataReader.maxDocumentBytes) + 1)
        let url = try await Fixtures.epub(["OEBPS/content.opf": huge])
        #expect(throws: MetadataError.malformed("Entry too large: OEBPS/content.opf")) {
            try await reader.readMetadata(from: url)
        }
    }

    @Test func skipsOversizedCover() async throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Big Cover</dc:title></metadata>
          <manifest><item id="c" href="c.png" media-type="image/png" properties="cover-image"/></manifest>
          <spine/>
        </package>
        """
        let big = Data(repeating: 0, count: Int(EPUBMetadataReader.maxCoverBytes) + 1)
        let url = try await Fixtures.epub(["OEBPS/content.opf": Data(opf.utf8), "OEBPS/c.png": big])
        let m = try await reader.readMetadata(from: url)
        #expect(m.title == "Big Cover")
        #expect(m.coverImageData == nil)
    }

    @Test func detectsDRM() async throws {
        let encryption = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <EncryptedData><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/></EncryptedData>
        </encryption>
        """
        let url = try await Fixtures.epub(["META-INF/encryption.xml": Data(encryption.utf8), "OEBPS/content.opf": Data("<package/>".utf8)])
        #expect(throws: MetadataError.drmProtected) { try await reader.readMetadata(from: url) }
    }

    @Test func allowsFontObfuscation() async throws {
        let encryption = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <EncryptedData><EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/></EncryptedData>
        </encryption>
        """
        let opf = #"<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Fonts</dc:title></metadata></package>"#
        let url = try await Fixtures.epub(["META-INF/encryption.xml": Data(encryption.utf8), "OEBPS/content.opf": Data(opf.utf8)])
        #expect(try await reader.readMetadata(from: url).title == "Fonts")
    }

    // MARK: Helpers

    @Test(arguments: [
        ("images/a.png", "OEBPS", "OEBPS/images/a.png"),
        ("../Images/a.png", "OPS/Text", "OPS/Images/a.png"),
        ("a%20b.png", "", "a b.png"),
        ("ch1.xhtml#part2", "OEBPS", "OEBPS/ch1.xhtml"),
        ("./x.png", "A", "A/x.png"),
    ])
    func resolvesHrefs(href: String, base: String, expected: String) {
        #expect(EPUBMetadataReader.resolve(href, relativeTo: base) == expected)
    }

    @Test func plainTextStripsTagsAndEntities() {
        #expect(HTMLText.plain("<p>One &amp; two</p><p>Three&#33;</p>") == "One & two\nThree!")
    }
}
