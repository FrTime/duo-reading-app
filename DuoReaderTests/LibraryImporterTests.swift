import Foundation
import SwiftData
import Testing
@testable import DuoReader

@MainActor
struct LibraryImporterTests {
    let container: ModelContainer
    let booksFolder: URL
    let importer: LibraryImporter

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        booksFolder = Fixtures.temporaryURL("Books")
        importer = LibraryImporter(modelContainer: container, booksFolder: booksFolder)
    }

    nonisolated static func sampleEPUB(title: String = "Imported Book") throws -> URL {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(title)</dc:title><dc:creator>Ada Writer</dc:creator>
          </metadata>
          <manifest/><spine/>
        </package>
        """
        return try Fixtures.epub(["OEBPS/content.opf": Data(opf.utf8)])
    }

    private func allBooks() throws -> [Book] {
        try container.mainContext.fetch(FetchDescriptor<Book>(sortBy: [SortDescriptor(\.shelfOrder)]))
    }

    @Test func importsAnEPUBAndCopiesIt() async throws {
        let source = try Self.sampleEPUB()
        let outcome = await importer.importFile(source)

        guard case .imported(_, let title) = outcome else {
            Issue.record("Expected import, got \(outcome)"); return
        }
        #expect(title == "Imported Book")

        let books = try allBooks()
        let book = try #require(books.first)
        #expect(books.count == 1)
        #expect(book.authors == ["Ada Writer"])
        #expect(book.format == .epub)
        #expect(book.relativeFilePath == "\(book.id.uuidString).epub")
        let copy = booksFolder.appending(path: book.relativeFilePath)
        #expect(FileManager.default.contentsEqual(atPath: copy.path(), andPath: source.path()))
    }

    @Test func importsAPDF() async throws {
        let outcome = await importer.importFile(try Fixtures.pdf(title: "Paper"))
        guard case .imported(_, let title) = outcome else {
            Issue.record("Expected import, got \(outcome)"); return
        }
        #expect(title == "Paper")
    }

    @Test func detectsDuplicatesByContent() async throws {
        let source = try Self.sampleEPUB()
        let renamedCopy = Fixtures.temporaryURL("renamed.epub")
        try FileManager.default.createDirectory(at: renamedCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: renamedCopy)

        let outcomes = await importer.importFiles([source, renamedCopy])
        #expect(outcomes.count == 2)
        #expect(outcomes[1] == .duplicate(title: "Imported Book"))
        #expect(try allBooks().count == 1)
    }

    @Test func appendsToTheEndOfTheShelf() async throws {
        _ = await importer.importFile(try Self.sampleEPUB(title: "First"))
        _ = await importer.importFile(try Self.sampleEPUB(title: "Second"))
        let books = try allBooks()
        #expect(books.map(\.title) == ["First", "Second"])
        #expect(books.map(\.shelfOrder) == [0, 1])
    }

    @Test func rejectsUnsupportedFormats() async throws {
        let url = Fixtures.temporaryURL("notes.mobi")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        #expect(await importer.importFile(url) == .failed(fileName: "notes.mobi", reason: .unsupportedFormat))
        #expect(try allBooks().isEmpty)
    }

    @Test func reportsDamagedFilesAndLeavesNoCopy() async throws {
        let url = Fixtures.temporaryURL("broken.epub")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a zip".utf8).write(to: url)
        #expect(await importer.importFile(url) == .failed(fileName: "broken.epub", reason: .unreadable))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: booksFolder.path())) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func reportsDRM() async throws {
        let encryption = #"<encryption><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/></encryption>"#
        let url = try Fixtures.epub(["META-INF/encryption.xml": Data(encryption.utf8), "OEBPS/content.opf": Data("<package/>".utf8)],
                                    name: "locked.epub")
        #expect(await importer.importFile(url) == .failed(fileName: "locked.epub", reason: .drmProtected))
    }

    @Test nonisolated func sha256MatchesKnownValue() throws {
        let url = Fixtures.temporaryURL("abc.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: url)
        #expect(try LibraryImporter.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@MainActor
struct ImportSummaryTests {
    @Test func singleImportIsQuiet() {
        let s = ImportSummary(outcomes: [.imported(PersistentIdentifierStub.make(), title: "A")])
        #expect(s.isQuietSuccess)
        #expect(s.title.contains("A"))
    }

    @Test func failuresAreExplained() {
        let s = ImportSummary(outcomes: [
            .duplicate(title: "B"),
            .failed(fileName: "x.mobi", reason: .unsupportedFormat),
        ])
        #expect(!s.isQuietSuccess)
        #expect(s.message.contains("B"))
        #expect(s.message.contains("x.mobi"))
    }
}

/// A real PersistentIdentifier for summary tests, from a throwaway store.
@MainActor
enum PersistentIdentifierStub {
    static func make() -> PersistentIdentifier {
        let container = try! LibraryStore.makeContainer(inMemory: true)
        let book = Book(relativeFilePath: "x", contentHash: "x", format: .epub, title: "x")
        container.mainContext.insert(book)
        try! container.mainContext.save()
        return book.persistentModelID
    }
}
