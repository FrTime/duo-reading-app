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
        let first = try LibraryStore.openOrRecover(url: url)
        #expect(first.recoveredFrom == nil)
        first.container.mainContext.insert(Book(relativeFilePath: "x", contentHash: "x", format: .epub, title: "Kept"))
        try first.container.mainContext.save()

        let second = try LibraryStore.openOrRecover(url: url)
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

        let result = try LibraryStore.openOrRecover(url: url)

        let backup = try #require(result.recoveredFrom)
        #expect(FileManager.default.fileExists(atPath: backup.appending(path: "Library.store").path()))
        #expect(try result.container.mainContext.fetch(FetchDescriptor<Book>()).isEmpty)

        try LibraryStore.readopt(booksIn: books, into: result.container)
        let recovered = try ModelContext(result.container).fetch(FetchDescriptor<Book>())
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

    @Test func readoptKeepsTheOrderBooksWereAdded() throws {
        let books = root.appending(path: "Books")
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        let titles = ["First", "Second", "Third"]
        var ids: [UUID] = []
        for (i, title) in titles.enumerated() {
            let id = UUID()
            ids.append(id)
            let dest = books.appending(path: "\(id.uuidString).epub")
            try FileManager.default.copyItem(at: try LibraryImporterTests.sampleEPUB(title: title), to: dest)
            try FileManager.default.setAttributes(
                [.creationDate: Date(timeIntervalSince1970: 1_000_000 + Double(i) * 60)], ofItemAtPath: dest.path())
        }
        let container = try LibraryStore.makeContainer(inMemory: true)
        try LibraryStore.readopt(booksIn: books, into: container)

        let shelf = try ModelContext(container).fetch(FetchDescriptor<Book>(sortBy: [SortDescriptor(\.shelfOrder)]))
        #expect(shelf.map(\.title) == titles)
        #expect(shelf.map(\.id) == ids)
    }

    @Test func keepsOnlyTheNewestBackups() throws {
        let url = root.appending(path: "Library.store")
        let recovered = root.appending(path: "Recovered")
        for stamp in ["2026-01-01T00-00-00Z", "2026-02-01T00-00-00Z", "2026-03-01T00-00-00Z", "2026-04-01T00-00-00Z"] {
            try FileManager.default.createDirectory(at: recovered.appending(path: stamp), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: url)

        let newest = try LibraryStore.moveAside(storeAt: url)

        let left = try FileManager.default.contentsOfDirectory(atPath: recovered.path()).sorted()
        #expect(left.count == LibraryStore.backupsKept)
        #expect(left.contains(newest.lastPathComponent))
        #expect(!left.contains("2026-01-01T00-00-00Z"))
        #expect(!left.contains("2026-02-01T00-00-00Z"))
    }
}
