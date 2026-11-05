import Foundation
import SwiftData
import Testing
@testable import DuoReader

struct HTMLConverterTests {
    static let page = """
    <!DOCTYPE html>
    <html lang="fr"><head><title>Le Livre</title><meta name="author" content="Ada Writer">
    <script>alert('head')</script><style>body { background: url(http://evil/x.png) }</style></head>
    <body><div id="wrap">
    <h1>Le Livre</h1>
    <p>Intro <b>bold</b> &amp; <i>italic</i></p>
    <h2>One</h2>
    <p onclick="evil()">Hi <a href="javascript:steal()">bad</a> <a href="https://example.com">good</a><img src="http://tracker/x.png"><br></p>
    <script>alert(1)</script><iframe src="https://evil"></iframe>
    <h2>Two</h2>
    <p>Bye&nbsp;now</p><hr>
    </div></body></html>
    """

    @Test func splitsAtHeadingsAndStripsUnsafeMarkup() throws {
        let doc = try HTMLConverter.document(fromHTML: Self.page, fallbackTitle: "file")
        #expect(doc.title == "Le Livre")
        #expect(doc.authors == ["Ada Writer"])
        #expect(doc.language == "fr")
        #expect(doc.chapters.map(\.title) == [nil, "One", "Two"])

        let all = doc.chapters.map(\.body).joined()
        for banned in ["script", "onclick", "javascript", "<img", "iframe", "style", "tracker"] {
            #expect(!all.contains(banned), "\(banned) survived cleaning")
        }
        #expect(all.contains("<b>bold</b>"))
        #expect(all.contains("&amp;"))
        #expect(all.contains(#"<a href="https://example.com""#))
        #expect(all.contains("Bye&#xa0;now") || all.contains("Bye\u{00A0}now"))
    }

    @Test func outputIsWellFormedXHTML() async throws {
        let doc = try HTMLConverter.document(fromHTML: Self.page, fallbackTitle: "file")
        for (path, data) in EPUBWriter.files(for: doc) where path.hasSuffix(".xhtml") {
            let parser = XMLParser(data: data)
            #expect(parser.parse(), "\(path) isn't well-formed: \(parser.parserError.map { "\($0)" } ?? "")")
        }
    }

    @Test func plainPageWithoutHeadingsIsOneChapter() throws {
        let doc = try HTMLConverter.document(fromHTML: "<p>Just text.</p>loose words", fallbackTitle: "note")
        #expect(doc.title == "note")
        #expect(doc.chapters.count == 1)
        #expect(doc.chapters[0].body.contains("<p>Just text.</p>"))
        #expect(doc.chapters[0].body.contains("loose words"))
    }

    // MARK: AO3

    static let ao3Page = """
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8"><title>The Work - someone - Some Fandom [Archive of Our Own]</title></head>
    <body>
    <div id="preface">
      <p class="message"><b>The Work</b><br/>Posted originally on the <a href="http://archiveofourown.org/">Archive of Our Own</a>
      at <a href="http://archiveofourown.org/works/12345">http://archiveofourown.org/works/12345</a>.</p>
      <div class="meta">
        <dl class="tags">
          <dt>Rating:</dt><dd><a class="tag" href="http://archiveofourown.org/tags/Teen">Teen And Up Audiences</a></dd>
          <dt>Fandom:</dt><dd><a class="tag" href="http://archiveofourown.org/tags/F">Some Fandom</a></dd>
          <dt>Relationship:</dt><dd><a class="tag" href="http://archiveofourown.org/tags/R">A/B</a></dd>
        </dl>
        <h1>The Work</h1>
        <div class="byline">by <a rel="author" href="http://archiveofourown.org/users/someone">someone</a></div>
        <p>Summary</p>
        <blockquote class="userstuff"><p>A short summary.</p></blockquote>
      </div>
    </div>
    <div id="chapters" class="userstuff">
      <div class="meta group"><h2 class="heading">Chapter 1: Start</h2><p>Chapter Notes</p></div>
      <div class="userstuff"><p>First text.</p></div>
      <div class="meta group"><h2 class="heading">Chapter 2</h2></div>
      <div class="userstuff"><p>Second text.</p></div>
    </div>
    <div id="afterword"><p>End Notes</p></div>
    </body></html>
    """

    @Test func readsAO3Downloads() throws {
        let doc = try HTMLConverter.document(fromHTML: Self.ao3Page, fallbackTitle: "file")
        #expect(doc.title == "The Work")
        #expect(doc.authors == ["someone"])
        #expect(doc.publisher == "Archive of Our Own")
        #expect(doc.sourceIdentifiers == ["http://archiveofourown.org/works/12345"])
        #expect(doc.summary == "A short summary.")
        #expect(doc.chapters.map(\.title) == [nil, "Chapter 1: Start", "Chapter 2", "Afterword"])
        #expect(doc.chapters[1].body.contains("Chapter Notes"))
        #expect(doc.chapters[1].body.contains("First text."))
        #expect(!doc.chapters[1].body.contains("Second text."))
        #expect(doc.chapters[2].body.contains("Second text."))
    }

    @Test func ao3TagsSurviveTheTripThroughEPUB() async throws {
        let doc = try HTMLConverter.document(fromHTML: Self.ao3Page, fallbackTitle: "file")
        let url = Fixtures.temporaryURL("ao3.epub")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await EPUBWriter.write(doc, to: url)

        let metadata = try await EPUBMetadataReader().readMetadata(from: url)
        let ao3 = try #require(metadata.ao3)
        #expect(ao3.workURL == URL(string: "http://archiveofourown.org/works/12345"))
        #expect(ao3.rating == "Teen And Up Audiences")
        #expect(ao3.fandoms == ["Some Fandom"])
        #expect(ao3.relationships == ["A/B"])
    }

    @Test func aChaptersDivWithoutAO3IsGenericHTML() throws {
        let doc = try HTMLConverter.document(fromHTML: #"<div id="chapters"><h1>A</h1><p>x</p><h1>B</h1><p>y</p></div>"#, fallbackTitle: "f")
        #expect(doc.publisher == nil)
        #expect(doc.chapters.map(\.title) == ["A", "B"])
    }
}

@MainActor
struct HTMLImportTests {
    @Test func importsAnAO3HTMLDownload() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let importer = LibraryImporter(modelContainer: container, booksFolder: Fixtures.temporaryURL("Books"))
        let url = Fixtures.temporaryURL("The_Work.html")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(HTMLConverterTests.ao3Page.utf8).write(to: url)

        let outcome = await importer.importFile(url)
        guard case .imported(_, let title) = outcome else {
            Issue.record("Expected import, got \(outcome)"); return
        }
        #expect(title == "The Work")
        let book = try #require(try container.mainContext.fetch(FetchDescriptor<Book>()).first)
        #expect(book.format == .epub)
        #expect(book.ao3?.fandoms == ["Some Fandom"])
    }
}
