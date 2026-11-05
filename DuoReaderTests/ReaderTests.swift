import Foundation
import ReadiumShared
import ReadiumZIPFoundation
import SwiftData
import Testing
@testable import DuoReader

// MARK: - Saved place

@MainActor
struct ReadingPositionTests {
    private func makeBook() -> Book {
        Book(relativeFilePath: "abc.epub", contentHash: "h", format: .epub, title: "T")
    }

    @Test func recordsLocatorProgressAndDate() {
        let book = makeBook()
        let date = Date(timeIntervalSince1970: 1_000)
        book.recordReadingPosition(locatorJSON: #"{"href":"c1.xhtml"}"#, progression: 0.42, at: date)
        #expect(book.readingLocator == #"{"href":"c1.xhtml"}"#)
        #expect(book.progress == 0.42)
        #expect(book.lastOpened == date)
    }

    @Test(arguments: [(-0.5, 0.0), (1.7, 1.0), (0.0, 0.0), (1.0, 1.0)])
    func clampsProgress(input: Double, expected: Double) {
        let book = makeBook()
        book.recordReadingPosition(locatorJSON: "{}", progression: input)
        #expect(book.progress == expected)
    }

    @Test(arguments: [nil, Double.nan, Double.infinity])
    func keepsProgressWhenUnknown(progression: Double?) {
        let book = makeBook()
        book.progress = 0.3
        book.recordReadingPosition(locatorJSON: "{}", progression: progression)
        #expect(book.progress == 0.3)
        #expect(book.readingLocator == "{}")
    }

    @Test func resolvesFileInLibraryFolder() {
        let folder = URL(filePath: "/tmp/Books", directoryHint: .isDirectory)
        #expect(makeBook().fileURL(in: folder).path(percentEncoded: false) == "/tmp/Books/abc.epub")
    }

    @Test func savedLocatorRoundTrips() throws {
        let locator = Locator(
            href: AnyURL(string: "OEBPS/ch1.xhtml")!,
            mediaType: .xhtml,
            title: "Chapter 1",
            locations: .init(progression: 0.5, totalProgression: 0.1, position: 3)
        )
        let decoded = ReaderModel.savedLocator(try locator.jsonString())
        #expect(decoded == locator)
    }

    @Test(arguments: [nil, "", "not json", #"{"title":"no href"}"#])
    func unreadableSavedLocatorOpensAtStart(json: String?) {
        #expect(ReaderModel.savedLocator(json) == nil)
    }
}

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
struct SaveThrottleTests {
    @Test func coalescesRequestsIntoOneSave() async {
        let counter = Counter()
        let throttle = SaveThrottle(interval: .milliseconds(10)) { counter.value += 1 }
        for _ in 0 ..< 10 { throttle.request() }
        #expect(throttle.hasPendingSave)
        #expect(counter.value == 0)
        await throttle.waitForPendingSave()
        #expect(counter.value == 1)
        #expect(!throttle.hasPendingSave)
    }

    @Test func flushSavesImmediatelyAndCancelsPending() async {
        let counter = Counter()
        let throttle = SaveThrottle(interval: .seconds(60)) { counter.value += 1 }
        throttle.request()
        throttle.flush()
        #expect(counter.value == 1)
        #expect(!throttle.hasPendingSave)
    }

    @Test func requestsAfterASaveScheduleAnother() async {
        let counter = Counter()
        let throttle = SaveThrottle(interval: .milliseconds(1)) { counter.value += 1 }
        throttle.request()
        await throttle.waitForPendingSave()
        throttle.request()
        await throttle.waitForPendingSave()
        #expect(counter.value == 2)
    }
}

// MARK: - Opening books

@MainActor
struct PublicationLoaderTests {
    static func readableEPUB() async throws -> URL {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">urn:uuid:00000000-0000-0000-0000-000000000001</dc:identifier>
            <dc:title>Readable</dc:title>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
        </package>
        """
        func page(_ title: String) -> Data {
            Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(title)</title></head>
            <body><h1>\(title)</h1><p>\(String(repeating: "Words on a page. ", count: 200))</p></body></html>
            """.utf8)
        }
        let nav = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head>
        <body><nav epub:type="toc"><ol>
          <li><a href="c1.xhtml">One</a></li><li><a href="c2.xhtml">Two</a></li>
        </ol></nav></body></html>
        """.utf8)
        return try await Fixtures.epub([
            "OEBPS/content.opf": Data(opf.utf8),
            "OEBPS/nav.xhtml": nav,
            "OEBPS/c1.xhtml": page("One"),
            "OEBPS/c2.xhtml": page("Two"),
        ])
    }

    @Test func opensAnEPUBWithItsReadingOrderAndContents() async throws {
        // Publication isn't Sendable; tableOfContents() runs off the main actor.
        nonisolated(unsafe) let publication = try await PublicationLoader().open(try await Self.readableEPUB())
        defer { publication.close() }
        #expect(publication.metadata.title == "Readable")
        #expect(publication.readingOrder.count == 2)
        let toc = try await publication.tableOfContents().get()
        #expect(toc.map(\.title) == ["One", "Two"])
    }

    @Test func opensAPDF() async throws {
        let publication = try await PublicationLoader().open(try Fixtures.pdf(title: "Paper"))
        defer { publication.close() }
        #expect(publication.conforms(to: .pdf))
    }

    @Test func reportsAMissingFile() async {
        let url = Fixtures.temporaryURL("gone.epub")
        await #expect(throws: ReaderOpenError.fileMissing) {
            _ = try await PublicationLoader().open(url)
        }
    }

    @Test func reportsAFileItCannotRead() async throws {
        let url = Fixtures.temporaryURL("junk.epub")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("definitely not a book".utf8).write(to: url)
        await #expect(throws: ReaderOpenError.unreadable) {
            _ = try await PublicationLoader().open(url)
        }
    }

    @Test func reportsDRM() async throws {
        // An LCP licence marks the book as protected; Readium refuses to
        // render it without the licence's key.
        let epub = try await Self.readableEPUB()
        let archive = try await ReadiumZIPFoundation.Archive(url: epub, accessMode: .update)
        let licence = Data(#"{"id":"x","encryption":{"profile":"http://readium.org/lcp/basic-profile"}}"#.utf8)
        try await archive.addEntry(with: "META-INF/license.lcpl", type: .file, uncompressedSize: Int64(licence.count)) { position, size in
            licence.subdata(in: Int(position) ..< Int(position) + size)
        }
        await #expect(throws: ReaderOpenError.drmProtected) {
            _ = try await PublicationLoader().open(epub)
        }
    }
}

@MainActor
struct ReaderModelTests {
    private func insertBook(_ format: BookFormat, file: URL, in context: ModelContext) -> Book {
        let book = Book(relativeFilePath: file.lastPathComponent, contentHash: UUID().uuidString, format: format, title: "Book")
        context.insert(book)
        return book
    }

    @Test func opensAtTheStartAndBuildsANavigator() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let file = try await PublicationLoaderTests.readableEPUB()
        let book = insertBook(.epub, file: file, in: container.mainContext)
        let model = ReaderModel(book: book, booksFolder: file.deletingLastPathComponent())

        await model.load(in: container.mainContext)

        #expect(model.state == .ready)
        #expect(model.navigator != nil)
        #expect(book.lastOpened != nil)
        model.close()
    }

    @Test func savesThePlaceAndReopensThere() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let file = try await PublicationLoaderTests.readableEPUB()
        let book = insertBook(.epub, file: file, in: container.mainContext)
        try container.mainContext.save()
        let folder = file.deletingLastPathComponent()

        let first = ReaderModel(book: book, booksFolder: folder)
        await first.load(in: container.mainContext)
        let page = try #require(first.publication?.readingOrder.last)
        let locator = Locator(
            href: page.url(),
            mediaType: .xhtml,
            locations: .init(progression: 0.5, totalProgression: 0.75)
        )
        first.locationDidChange(locator)
        first.close()

        // A fresh context reads what was written to the store.
        let fresh = ModelContext(container)
        let bookID = book.id
        let stored = try #require(try fresh.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })).first)
        #expect(stored.progress == 0.75)
        let saved = try #require(ReaderModel.savedLocator(stored.readingLocator))
        #expect(saved.href == locator.href)
        #expect(saved.locations.progression == 0.5)

        let second = ReaderModel(book: stored, booksFolder: folder)
        await second.load(in: fresh)
        #expect(second.navigator?.currentLocation?.href == locator.href)
        second.close()
    }

    @Test func closingWhileLoadingLeavesNothingOpen() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let file = try await PublicationLoaderTests.readableEPUB()
        let book = insertBook(.epub, file: file, in: container.mainContext)
        let model = ReaderModel(book: book, booksFolder: file.deletingLastPathComponent())

        model.close()
        await model.load(in: container.mainContext)

        #expect(model.navigator == nil)
        #expect(model.state != .ready)
    }

    @Test func onlyWebAndMailLinksMayLeaveTheApp() {
        #expect(ExternalLinkPolicy.allows(URL(string: "https://archiveofourown.org/works/1")!))
        #expect(ExternalLinkPolicy.allows(URL(string: "HTTP://example.com")!))
        #expect(ExternalLinkPolicy.allows(URL(string: "mailto:a@b.c")!))
        #expect(!ExternalLinkPolicy.allows(URL(string: "tel:5551234")!))
        #expect(!ExternalLinkPolicy.allows(URL(string: "sms:5551234")!))
        #expect(!ExternalLinkPolicy.allows(URL(string: "someapp://do-something")!))
    }

    @Test func failsCleanlyWhenTheFileIsGone() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let file = Fixtures.temporaryURL("missing.epub")
        let book = insertBook(.epub, file: file, in: container.mainContext)
        let model = ReaderModel(book: book, booksFolder: file.deletingLastPathComponent())

        await model.load(in: container.mainContext)

        #expect(model.state == .failed(.fileMissing))
        #expect(model.navigator == nil)
    }

    @Test func refusesFormatsThatNeedConverting() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let file = Fixtures.temporaryURL("notes.txt")
        let book = insertBook(.txt, file: file, in: container.mainContext)
        let model = ReaderModel(book: book, booksFolder: file.deletingLastPathComponent())

        await model.load(in: container.mainContext)

        #expect(model.state == .failed(.unsupportedFormat))
    }
}

// MARK: - Reader chrome

struct TapZoneTests {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)

    @Test(arguments: [
        (CGPoint(x: 10, y: 400), TapZone.left),
        (CGPoint(x: 99, y: 10), TapZone.left),
        (CGPoint(x: 200, y: 400), TapZone.center),
        (CGPoint(x: 301, y: 790), TapZone.right),
        (CGPoint(x: 399, y: 400), TapZone.right),
    ])
    func splitsThePageIntoZones(point: CGPoint, zone: TapZone) {
        #expect(TapZone(point: point, in: bounds, edgeFraction: 0.25) == zone)
    }

    @Test func emptyBoundsCountAsCenter() {
        #expect(TapZone(point: .zero, in: .zero, edgeFraction: 0.25) == .center)
    }
}

struct ReaderProgressTextTests {
    @Test func showsLocationAndPercentWhenKnown() {
        let text = ReaderProgressText.summary(progression: 0.25, position: 12, positionCount: 48)
        #expect(text.contains("12"))
        #expect(text.contains("48"))
        #expect(text.contains("25"))
    }

    @Test func fallsBackToPercent() {
        #expect(ReaderProgressText.summary(progression: 0.5, position: nil, positionCount: nil).contains("50"))
    }

    @Test func isEmptyWhenNothingIsKnown() {
        #expect(ReaderProgressText.summary(progression: nil, position: 3, positionCount: nil).isEmpty)
    }
}
