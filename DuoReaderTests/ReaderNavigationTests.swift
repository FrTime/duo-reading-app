import Foundation
import ReadiumShared
import SwiftData
import Testing
@testable import DuoReader

struct TOCEntryTests {
    @Test func flattensNestedContentsInReadingOrder() {
        let toc = [
            Link(href: "c1.xhtml", title: "Part One", children: [
                Link(href: "c1.xhtml#s1", title: "Chapter 1"),
                Link(href: "c2.xhtml", title: "  ", children: [Link(href: "c2.xhtml#a", title: "Deep")]),
            ]),
            Link(href: "c3.xhtml", title: "Part Two"),
        ]
        let entries = TOCEntry.flatten(toc)
        #expect(entries.map(\.title) == ["Part One", "Chapter 1", "Untitled", "Deep", "Part Two"])
        #expect(entries.map(\.depth) == [0, 1, 1, 2, 0])
        #expect(entries.map(\.id) == [0, 1, 2, 3, 4])
        #expect(entries[1].resourceHref == "c1.xhtml")
    }

    private let entries = TOCEntry.flatten([
        Link(href: "c1.xhtml", title: "Chapter 1", children: [
            Link(href: "c1.xhtml#s1", title: "Section A"),
            Link(href: "c1.xhtml#s2", title: "Section B"),
        ]),
        Link(href: "c3.xhtml", title: "Chapter 2"),
    ])
    private let order = ["c1.xhtml", "c2.xhtml", "c3.xhtml"]

    @Test func theChapterIsCurrentRatherThanItsLastSection() {
        #expect(TOCEntry.currentID(in: entries, readingOrder: order, current: "c1.xhtml") == 0)
    }

    @Test func aChapterSpanningFilesStaysCurrent() {
        // c2 isn't listed: it's the second file of chapter 1.
        #expect(TOCEntry.currentID(in: entries, readingOrder: order, current: "c2.xhtml") == 2)
        #expect(TOCEntry.currentID(in: entries, readingOrder: order, current: "c3.xhtml") == 3)
    }

    @Test func pathsMatchDespiteEncodingAndFragments() {
        let spaced = TOCEntry.flatten([Link(href: "my%20chapter.xhtml#top", title: "One")])
        #expect(TOCEntry.currentID(in: spaced, readingOrder: ["my chapter.xhtml"], current: "my%20chapter.xhtml") == 0)
    }
}

@MainActor
struct ReaderNavigationTests {
    private func openModel() async throws -> (ReaderModel, ModelContainer) {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let file = try await PublicationLoaderTests.readableEPUB()
        let book = Book(relativeFilePath: file.lastPathComponent, contentHash: UUID().uuidString, format: .epub, title: "Book")
        container.mainContext.insert(book)
        let model = ReaderModel(book: book, booksFolder: file.deletingLastPathComponent())
        await model.load(in: container.mainContext)
        return (model, container)
    }

    @Test func loadsTheContents() async throws {
        let (model, container) = try await openModel()
        defer { model.close(); withExtendedLifetime(container) {} }
        #expect(model.tableOfContents.map(\.title) == ["One", "Two"])
    }

    @Test(.timeLimit(.minutes(1))) func jumpingRemembersWhereYouWere() async throws {
        let (model, container) = try await openModel()
        defer { model.close(); withExtendedLifetime(container) {} }
        let start = try #require(model.publication?.readingOrder.first)
        model.locationDidChange(Locator(href: start.url(), mediaType: .xhtml, locations: .init(progression: 0, totalProgression: 0.1)))

        let chapterTwo = try #require(model.tableOfContents.last)
        await model.go(to: chapterTwo.link)

        #expect(model.returnLocator?.locations.totalProgression == 0.1)
        model.clearReturnPoint()
        #expect(model.returnLocator == nil)
    }

    @Test(.timeLimit(.minutes(1))) func severalJumpsStillLeadBackToTheStart() async throws {
        let (model, container) = try await openModel()
        defer { model.close(); withExtendedLifetime(container) {} }
        let start = try #require(model.publication?.readingOrder.first)
        model.locationDidChange(Locator(href: start.url(), mediaType: .xhtml, locations: .init(progression: 0, totalProgression: 0.1)))

        await model.go(to: try #require(model.tableOfContents.last).link)
        let later = try #require(model.publication?.readingOrder.last)
        model.locationDidChange(Locator(href: later.url(), mediaType: .xhtml, locations: .init(progression: 0, totalProgression: 0.8)))
        await model.go(to: try #require(model.tableOfContents.first).link)

        #expect(model.returnLocator?.locations.totalProgression == 0.1)
    }

    @Test func scrubbingRejectsNonsense() async throws {
        let (model, container) = try await openModel()
        defer { model.close(); withExtendedLifetime(container) {} }
        #expect(await model.go(toProgression: .nan) == false)
    }

    @Test func findsTextInTheBook() async throws {
        let (model, container) = try await openModel()
        defer { model.close(); withExtendedLifetime(container) {} }
        #expect(model.isSearchable)
        let results = await model.search("Words on a page", limit: 5)
        #expect(results.count == 5)
        #expect(results.first?.text.highlight?.localizedCaseInsensitiveContains("words on a page") == true)
        #expect(await model.search("   ").isEmpty)
        #expect(await model.search("zebra crossing").isEmpty)
    }
}
