import Foundation
import SwiftData
import Testing
@testable import DuoReader

struct ZippedBookTests {
    static func zippedFB2(name: String) async throws -> URL {
        try await ComicConverterTests.zip([
            ("__MACOSX/._road.fb2", Data("junk".utf8)),
            ("road.fb2", Data(FB2ConverterTests.book.utf8)),
        ], name: name)
    }

    @Test func fb2ZipIsRecognisedByName() {
        #expect(BookFormat(url: URL(filePath: "/x/The Road.fb2.zip")) == .fb2)
        #expect(BookFormat(url: URL(filePath: "/x/The Road.FB2.ZIP")) == .fb2)
        #expect(BookFormat(url: URL(filePath: "/x/archive.zip")) == nil)
    }

    @Test func sniffsWhatAZipHolds() async throws {
        #expect(await ZIPSniffer.bookFormat(ofZIP: try await Self.zippedFB2(name: "a.zip")) == .fb2)
        #expect(await ZIPSniffer.bookFormat(ofZIP: try await ComicConverterTests.sampleComic(name: "pages.zip")) == .cbz)
        let notes = try await ComicConverterTests.zip([("readme.txt", Data("x".utf8))], name: "notes.zip")
        #expect(await ZIPSniffer.bookFormat(ofZIP: notes) == nil)
        let mixed = try await ComicConverterTests.zip([
            ("cover.png", Fixtures.tinyPNG), ("report.pdf", Data("%PDF".utf8)),
        ], name: "mixed.zip")
        #expect(await ZIPSniffer.bookFormat(ofZIP: mixed) == nil)
        #expect(await ZIPSniffer.bookFormat(ofZIP: Fixtures.temporaryURL("missing.zip")) == nil)
    }

    @Test func fb2ConverterUnzipsFirst() async throws {
        let doc = try await FB2Converter().document(from: try await Self.zippedFB2(name: "road.fb2.zip"))
        #expect(doc.title == "The Long Road")
        #expect(doc.coverImage == Fixtures.tinyPNG)
        let empty = try await ComicConverterTests.zip([("readme.txt", Data("x".utf8))], name: "empty.fb2.zip")
        await #expect(throws: ConversionError.unreadable) { _ = try await FB2Converter().document(from: empty) }
    }
}

@MainActor
struct ZippedBookImportTests {
    @Test func importsZippedFB2AndComicsAndRejectsOtherZips() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let importer = LibraryImporter(modelContainer: container, booksFolder: Fixtures.temporaryURL("Books"))

        guard case .imported = await importer.importFile(try await ZippedBookTests.zippedFB2(name: "road.fb2.zip")) else {
            Issue.record("road.fb2.zip"); return
        }
        guard case .imported = await importer.importFile(try await ComicConverterTests.sampleComic(name: "moss.zip")) else {
            Issue.record("moss.zip"); return
        }
        let notes = try await ComicConverterTests.zip([("readme.txt", Data("x".utf8))], name: "notes.zip")
        #expect(await importer.importFile(notes) == .failed(fileName: "notes.zip", reason: .unsupportedFormat))

        let books = try container.mainContext.fetch(FetchDescriptor<Book>(sortBy: [SortDescriptor(\.shelfOrder)]))
        #expect(books.count == 2)
        #expect(books.first?.title == "The Long Road")
        #expect(books.allSatisfy { $0.format == .epub })
    }
}
