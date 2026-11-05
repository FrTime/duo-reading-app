import Foundation
import SwiftData
import Testing
@testable import DuoReader

@MainActor
struct LibraryQueryTests {
    func book(_ title: String, authors: [String] = [], order: Int = 0, added: Date = .now, opened: Date? = nil,
              fandoms: [String] = []) -> Book {
        let b = Book(relativeFilePath: title, contentHash: title, format: .epub, title: title,
                     authors: authors, dateAdded: added, shelfOrder: order)
        b.lastOpened = opened
        if !fandoms.isEmpty {
            var ao3 = AO3Metadata(); ao3.fandoms = fandoms; b.ao3 = ao3
        }
        return b
    }

    @Test func emptySearchMatchesEverything() {
        let books = [book("A"), book("B")]
        #expect(LibraryQuery.filter(books, matching: "  ").count == 2)
    }

    @Test func searchMatchesTitleAuthorAndFandomIgnoringCaseAndAccents() {
        let books = [
            book("Café Society", authors: ["Zoë Ray"]),
            book("Other", fandoms: ["Star Saga"]),
            book("Third"),
        ]
        #expect(LibraryQuery.filter(books, matching: "cafe").map(\.title) == ["Café Society"])
        #expect(LibraryQuery.filter(books, matching: "ZOE").map(\.title) == ["Café Society"])
        #expect(LibraryQuery.filter(books, matching: "star saga").map(\.title) == ["Other"])
        #expect(LibraryQuery.filter(books, matching: "saga third").isEmpty)
    }

    @Test func sortsByTitleIgnoringArticles() {
        let books = [book("The Hobbit"), book("A Zebra"), book("Apple"), book("book 10"), book("book 9")]
        #expect(LibraryQuery.sort(books, by: .title).map(\.title) == ["Apple", "book 9", "book 10", "The Hobbit", "A Zebra"])
    }

    @Test func sortsByAuthorThenTitleWithUnknownLast() {
        let books = [book("Z", authors: ["Bee"]), book("No Author"), book("A", authors: ["Bee"]), book("M", authors: ["Ant"])]
        #expect(LibraryQuery.sort(books, by: .author).map(\.title) == ["M", "A", "Z", "No Author"])
    }

    @Test func sortsByShelfOrder() {
        let books = [book("Two", order: 2), book("Zero", order: 0), book("One", order: 1)]
        #expect(LibraryQuery.sort(books, by: .shelf).map(\.title) == ["Zero", "One", "Two"])
    }

    @Test func recentlyReadPutsOpenedBooksFirst() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let books = [
            book("Never old", added: t),
            book("Opened earlier", opened: t.addingTimeInterval(10)),
            book("Never new", added: t.addingTimeInterval(100)),
            book("Opened later", opened: t.addingTimeInterval(20)),
        ]
        #expect(LibraryQuery.sort(books, by: .recentlyOpened).map(\.title)
                == ["Opened later", "Opened earlier", "Never new", "Never old"])
    }

    @Test func recentlyAddedNewestFirst() {
        let t = Date(timeIntervalSince1970: 0)
        let books = [book("Old", added: t), book("New", added: t.addingTimeInterval(5))]
        #expect(LibraryQuery.sort(books, by: .recentlyAdded).map(\.title) == ["New", "Old"])
    }
}

@MainActor
struct LibraryActionsTests {
    @Test func deleteRemovesBookFileAndNotifies() throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let folder = Fixtures.temporaryURL("Books")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let book = Book(relativeFilePath: "b.epub", contentHash: "h", format: .epub, title: "Gone")
        try Data("x".utf8).write(to: folder.appending(path: "b.epub"))
        container.mainContext.insert(book)
        try container.mainContext.save()

        var notified: [UUID] = []
        let previous = LibraryActions.onDelete
        LibraryActions.onDelete = [{ notified.append($0) }]
        defer { LibraryActions.onDelete = previous }

        let id = book.id
        try LibraryActions.delete(book, in: container.mainContext, booksFolder: folder)

        #expect(try container.mainContext.fetch(FetchDescriptor<Book>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "b.epub").path()))
        #expect(notified == [id])
    }

    @Test func deleteSucceedsWhenFileIsAlreadyGone() throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let book = Book(relativeFilePath: "missing.epub", contentHash: "h", format: .epub, title: "Ghost")
        container.mainContext.insert(book)
        try LibraryActions.delete(book, in: container.mainContext, booksFolder: Fixtures.temporaryURL("none"))
        #expect(try container.mainContext.fetch(FetchDescriptor<Book>()).isEmpty)
    }
}
