import Foundation
import SwiftData
import Testing
@testable import DuoReader

struct FileNameTitleTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let fileName: String
        let title: String
        var series: String?
        var index: Double?
        var testDescription: String { fileName }
    }

    @Test(arguments: [
        Case(fileName: "Claymore v15 (2009) (Digital) (LostNerevarine-Empire).cbz", title: "Claymore, Vol. 15", series: "Claymore", index: 15),
        Case(fileName: "[Group] Berserk_v01_c003 [1080p].cbz", title: "Berserk, Vol. 1, Ch. 3", series: "Berserk", index: 1),
        Case(fileName: "Berserk.v01.c003.cbz", title: "Berserk, Vol. 1, Ch. 3", series: "Berserk", index: 1),
        Case(fileName: "Vagabond Vol.03 - The Way.cbz", title: "Vagabond, Vol. 3: The Way", series: "Vagabond", index: 3),
        Case(fileName: "One Piece - Chapter 1001.cbz", title: "One Piece, Ch. 1001", series: "One Piece", index: 1001),
        Case(fileName: "Love Hina v02 HQ.cbz", title: "Love Hina, Vol. 2", series: "Love Hina", index: 2),
        Case(fileName: "Akira Tome 4.cbz", title: "Akira, Vol. 4", series: "Akira", index: 4),
        Case(fileName: "Saga 004 (2012) (digital).cbz", title: "Saga #4", series: "Saga", index: 4),
        Case(fileName: "Saga #4.cbz", title: "Saga #4", series: "Saga", index: 4),
        Case(fileName: "Berserk v01-03.cbz", title: "Berserk, Vol. 1–3", series: "Berserk", index: 1),
        Case(fileName: "Some_Comic.cbz", title: "Some Comic"),
        Case(fileName: "Catch 22.pdf", title: "Catch 22"),
        Case(fileName: "[Only Tags].cbz", title: "Only Tags"),
        Case(fileName: "Charlotte's Web.epub", title: "Charlotte's Web"),
        Case(fileName: "Born Digital.pdf", title: "Born Digital"),
        Case(fileName: "OnePiece.Ch.1001.5.cbz", title: "OnePiece, Ch. 1001.5", series: "OnePiece", index: 1001.5),
    ])
    func parses(_ example: Case) {
        let parsed = FileNameTitle(fileName: example.fileName)
        #expect(parsed.title == example.title)
        #expect(parsed.series == example.series)
        #expect(parsed.seriesIndex == example.index)
    }

    @Test func readsTheYearFromBrackets() {
        #expect(FileNameTitle(fileName: "Claymore v15 (2009) (Digital).cbz").year == 2009)
    }

    @Test func cleaningIsStable() {
        let once = FileNameTitle(fileName: "Claymore v15 (2009) (Digital).cbz")
        #expect(FileNameTitle(fileName: once.title) == FileNameTitle(fileName: "Claymore v15"))
        #expect(FileNameTitle(fileName: once.title).title == once.title)
    }

    @Test func numbersAreWrittenTheSameInEveryLocale() {
        #expect(FileNameTitleParser.number(10.5) == "10.5")
        #expect(FileNameTitleParser.number(1234.5) == "1234.5")
        #expect(FileNameTitleParser.number(15) == "15")
    }

    @Test func onlyKnownExtensionsAreDropped() {
        #expect(FileNameTitleParser.stripExtension("Claymore, Vol. 15") == "Claymore, Vol. 15")
        #expect(FileNameTitleParser.stripExtension("Story.epub") == "Story")
    }
}

@MainActor
struct TitleCleanupTests {
    let container: ModelContainer

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
    }

    private func book(title: String, fileName: String? = nil, series: String? = nil) -> Book {
        let book = Book(relativeFilePath: "x.epub", contentHash: UUID().uuidString, format: .epub, title: title)
        book.originalFileName = fileName
        book.series = series
        container.mainContext.insert(book)
        return book
    }

    @Test func suggestsACleanupForATitleMadeFromTheFileName() throws {
        let name = "Claymore v15 (2009) (Digital) (LostNerevarine-Empire)"
        let book = book(title: name)
        let cleanup = try #require(book.suggestedTitleCleanup)
        #expect(cleanup == TitleCleanup(title: "Claymore, Vol. 15", series: "Claymore", seriesIndex: 15))

        book.apply(cleanup)
        #expect(book.title == "Claymore, Vol. 15")
        #expect(book.series == "Claymore")
        #expect(book.seriesIndex == 15)
        // The old title is kept as the file name, so it can be put back.
        #expect(book.originalFileName == name)
        #expect(book.plainFileNameTitle == name)
        #expect(book.suggestedTitleCleanup == nil)
    }

    @Test func leavesTitlesFromMetadataOrTheUserAlone() {
        let fromMetadata = book(title: "The Black Swordsman", fileName: "Berserk v01 (Digital).epub")
        #expect(fromMetadata.suggestedTitleCleanup == nil)
        let tidy = book(title: "Claymore, Vol. 15", fileName: "Claymore v15 (2009).cbz", series: "Claymore")
        #expect(tidy.suggestedTitleCleanup == nil)
    }

    @Test func olderBooksWithAnAuthorAreNotOffered() {
        let book = book(title: "Dune (Dune Chronicles, Book 1)")
        book.authors = ["Frank Herbert"]
        #expect(book.suggestedTitleCleanup == nil)
    }

    @Test func keepsASeriesTheBookAlreadyHas() {
        let book = book(title: "Berserk v01 (Digital)", series: "Berserk Deluxe")
        book.seriesIndex = 7
        book.apply(book.cleanedTitle)
        #expect(book.title == "Berserk, Vol. 1")
        #expect(book.series == "Berserk Deluxe")
        #expect(book.seriesIndex == 7)
    }

    @Test func plainFileNameTitleKeepsTheTags() {
        let book = book(title: "Claymore, Vol. 15", fileName: "Claymore_v15_(2009).cbz")
        #expect(book.plainFileNameTitle == "Claymore v15 (2009)")
    }
}

@MainActor
struct ComicFileNameImportTests {
    @Test func comicWithoutComicInfoGetsItsTitleAndSeriesFromTheFileName() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let importer = LibraryImporter(modelContainer: container, booksFolder: Fixtures.temporaryURL("Books"))
        let name = "Claymore v15 (2009) (Digital) (LostNerevarine-Empire).cbz"
        let source = try await ComicConverterTests.zip([("Claymore, Vol. 15/001.png", ComicConverterTests.page1)], name: name)

        guard case .imported(_, let title) = await importer.importFile(source) else {
            Issue.record("Expected an import"); return
        }
        #expect(title == "Claymore, Vol. 15")
        let book = try #require(try container.mainContext.fetch(FetchDescriptor<Book>()).first)
        #expect(book.series == "Claymore")
        #expect(book.seriesIndex == 15)
        #expect(book.originalFileName == name)
        #expect(book.suggestedTitleCleanup == nil)
    }

    @Test func comicInfoNumberIsKeptWhenOnlyTheSeriesComesFromTheFileName() async throws {
        let info = Data("<?xml version=\"1.0\"?><ComicInfo><Number>12</Number></ComicInfo>".utf8)
        let source = try await ComicConverterTests.zip([("001.png", ComicConverterTests.page1), ("ComicInfo.xml", info)], name: "Saga 004.cbz")
        let output = source.deletingLastPathComponent().appending(path: "out.epub")
        try await ComicConverter().convert(source, to: output)
        let metadata = try await EPUBMetadataReader().readMetadata(from: output)
        #expect(metadata.series == "Saga")
        #expect(metadata.seriesIndex == 12)
    }

    @Test func comicInfoStillWinsOverTheFileName() async throws {
        let source = try await ComicConverterTests.sampleComic(name: "Moss v09 (Digital).cbz")
        let output = source.deletingLastPathComponent().appending(path: "out.epub")
        try await ComicConverter().convert(source, to: output)
        let metadata = try await EPUBMetadataReader().readMetadata(from: output)
        #expect(metadata.title == "Moss & Stone #3")
        #expect(metadata.series == "Moss & Stone")
        #expect(metadata.seriesIndex == 3)
    }
}
