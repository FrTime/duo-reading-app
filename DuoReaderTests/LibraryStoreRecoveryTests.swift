import Foundation
import SwiftData
import Testing
@testable import DuoReader

@MainActor
struct LibraryStoreRecoveryTests {
    let root = Fixtures.temporaryURL("Store")

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @Test func opensAHealthyStoreWithoutRecovery() throws {
        let url = root.appending(path: "Library.store")
        let first = try LibraryStore.openOrRecover(url: url, booksFolder: root.appending(path: "Books"))
        #expect(first.recoveredFrom == nil)
        first.container.mainContext.insert(Book(relativeFilePath: "x", contentHash: "x", format: .epub, title: "Kept"))
        try first.container.mainContext.save()

        let second = try LibraryStore.openOrRecover(url: url, booksFolder: root.appending(path: "Books"))
        #expect(second.recoveredFrom == nil)
        #expect(try second.container.mainContext.fetch(FetchDescriptor<Book>()).map(\.title) == ["Kept"])
    }

    @Test func recoversFromACorruptStoreAndReadoptsBooks() throws {
        let url = root.appending(path: "Library.store")
        try Data("this is not a sqlite database".utf8).write(to: url)

        let books = root.appending(path: "Books")
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        let id = UUID()
        let epub = try LibraryImporterTests.sampleEPUB(title: "Survivor")
        try FileManager.default.copyItem(at: epub, to: books.appending(path: "\(id.uuidString).epub"))
        try Data("ignore me".utf8).write(to: books.appending(path: "notes.txt"))

        let result = try LibraryStore.openOrRecover(url: url, booksFolder: books)

        let backup = try #require(result.recoveredFrom)
        #expect(FileManager.default.fileExists(atPath: backup.appending(path: "Library.store").path()))
        let recovered = try result.container.mainContext.fetch(FetchDescriptor<Book>())
        #expect(recovered.count == 1)
        #expect(recovered.first?.id == id)
        #expect(recovered.first?.title == "Survivor")
        #expect(recovered.first?.relativeFilePath == "\(id.uuidString).epub")
    }

    @Test func movesCompanionFilesAside() throws {
        let url = root.appending(path: "Library.store")
        for suffix in ["", "-shm", "-wal"] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: url.path() + suffix))
        }
        let folder = try LibraryStore.moveAside(storeAt: url)
        for suffix in ["", "-shm", "-wal"] {
            #expect(!FileManager.default.fileExists(atPath: url.path() + suffix))
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Library.store\(suffix)").path()))
        }
    }
}
