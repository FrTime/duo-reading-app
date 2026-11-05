import Foundation
import SwiftData
import Testing
@testable import DuoReader

@MainActor
struct LibraryStoreTests {
    @Test func savesAndFetchesABook() throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let book = Book(
            relativeFilePath: "Books/abc.epub",
            contentHash: "abc",
            format: .epub,
            title: "A Study in Scarlet",
            authors: ["Arthur Conan Doyle"]
        )
        context.insert(book)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Book>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "A Study in Scarlet")
        #expect(fetched.first?.format == .epub)
        #expect(fetched.first?.progress == 0)
    }

    @Test func unknownFormatFallsBackToEpub() {
        let book = Book(relativeFilePath: "x", contentHash: "x", format: .pdf, title: "X")
        book.formatRawValue = "something-new"
        #expect(book.format == .epub)
    }

    @Test func displayAuthorsHandlesNone() {
        let book = Book(relativeFilePath: "x", contentHash: "x", format: .pdf, title: "X")
        #expect(!book.displayAuthors.isEmpty)
    }
}

@MainActor
struct BookApplyMetadataTests {
    @Test func appliesMetadataAndKeepsAO3() throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let book = Book(relativeFilePath: "x", contentHash: "x", format: .epub, title: "")
        container.mainContext.insert(book)
        var m = BookMetadata()
        m.title = "Title"
        m.authors = ["A"]
        var ao3 = AO3Metadata()
        ao3.fandoms = ["F"]
        m.ao3 = ao3
        m.coverImageData = Data([1, 2, 3])
        book.apply(m, fileURL: URL(fileURLWithPath: "/tmp/file.epub"))
        try container.mainContext.save()

        let fetched = try #require(try container.mainContext.fetch(FetchDescriptor<Book>()).first)
        #expect(fetched.title == "Title")
        #expect(fetched.ao3?.fandoms == ["F"])
        #expect(fetched.coverImageData == Data([1, 2, 3]))
    }

    @Test func fallsBackToFileNameForTitle() {
        let book = Book(relativeFilePath: "x", contentHash: "x", format: .pdf, title: "")
        book.apply(BookMetadata(), fileURL: URL(fileURLWithPath: "/tmp/My_Great_Book.pdf"))
        #expect(book.title == "My Great Book")
    }
}
