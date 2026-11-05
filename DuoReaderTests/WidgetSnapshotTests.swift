import Foundation
import SwiftData
import Testing
import UIKit
@testable import DuoReader

struct WidgetSnapshotTests {
    private func book(_ title: String = "Book", progress: Double = 0, opened: Date? = nil, thickness: Double = 0.12) -> WidgetSnapshot.Book {
        let color = WidgetSnapshot.Color(red: 0.2, green: 0.3, blue: 0.4)
        return WidgetSnapshot.Book(id: UUID(), title: title, author: "A", progress: progress, thickness: thickness,
                                   baseColor: color, spineColor: color, lastOpened: opened)
    }

    private func tempStore() -> WidgetStore {
        WidgetStore(root: FileManager.default.temporaryDirectory.appending(path: "widgets-\(UUID().uuidString)"))
    }

    // MARK: Current book

    @Test func currentIsMostRecentlyOpenedUnfinishedBook() {
        let old = book("Old", progress: 0.3, opened: .now.addingTimeInterval(-500))
        let finished = book("Done", progress: 1, opened: .now)
        let never = book("Never")
        #expect(WidgetSnapshot.pickCurrent(from: [never, finished, old])?.title == "Old")
    }

    @Test func currentFallsBackToFinishedBook() {
        let finished = book("Done", progress: 0.999, opened: .now)
        #expect(WidgetSnapshot.pickCurrent(from: [finished, book("Never")])?.title == "Done")
    }

    @Test func noCurrentWhenNothingOpened() {
        #expect(WidgetSnapshot.pickCurrent(from: [book(), book()]) == nil)
    }

    @Test(arguments: [(0.0, 0), (0.645, 64), (0.999, 99), (1.0, 100), (1.7, 100), (-1.0, 0)])
    func percentIsClampedAndRoundedDown(progress: Double, expected: Int) {
        #expect(book(progress: progress).percent == expected)
    }

    @Test func shelfStyleDefaultsToSpines() {
        #expect(WidgetSnapshot.ShelfStyle(storedValue: nil) == .spines)
        #expect(WidgetSnapshot.ShelfStyle(storedValue: "nonsense") == .spines)
        #expect(WidgetSnapshot.ShelfStyle(storedValue: "covers") == .covers)
    }

    // MARK: Store

    @Test func storeRoundTripsSnapshot() throws {
        let store = tempStore()
        let books = [book("One", progress: 0.5, opened: .now), book("Two")]
        let snapshot = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 1_000_000), shelfStyle: .covers,
                                      totalBookCount: 2, books: books, current: books[0])
        try store.save(snapshot)
        let loaded = try #require(store.load())
        #expect(loaded.hasSameContent(as: snapshot))
        #expect(loaded.shelfStyle == .covers)
        #expect(loaded.current?.title == "One")
    }

    @Test func storeIgnoresOtherVersions() throws {
        let store = tempStore()
        var snapshot = WidgetSnapshot(generatedAt: .now, shelfStyle: .spines, totalBookCount: 0, books: [], current: nil)
        snapshot.version = WidgetSnapshot.currentVersion + 1
        try store.save(snapshot)
        #expect(store.load() == nil)
    }

    @Test func sameContentIgnoresGeneratedAt() {
        let a = WidgetSnapshot(generatedAt: .now, shelfStyle: .spines, totalBookCount: 0, books: [], current: nil)
        var b = a
        b.generatedAt = .distantPast
        #expect(a.hasSameContent(as: b))
        b.shelfStyle = .covers
        #expect(!a.hasSameContent(as: b))
        #expect(!a.hasSameContent(as: nil))
    }

    // MARK: Links

    @Test func bookLinkRoundTrips() {
        let id = UUID()
        let url = WidgetLink.url(forBook: id)
        #expect(WidgetLink.isWidgetLink(url))
        #expect(WidgetLink.bookID(from: url) == id)
    }

    @Test func otherURLsAreNotBookLinks() {
        #expect(WidgetLink.bookID(from: WidgetLink.library) == nil)
        #expect(WidgetLink.bookID(from: URL(string: "duoreader://book/not-a-uuid")!) == nil)
        #expect(WidgetLink.bookID(from: URL(string: "duoreader://book/\(UUID())/extra")!) == nil)
        let file = URL(fileURLWithPath: "/tmp/book.epub")
        #expect(!WidgetLink.isWidgetLink(file))
        #expect(WidgetLink.bookID(from: file) == nil)
    }

    // MARK: Shelf layout

    @Test func spinesFillRowsInOrderAndWrap() {
        // Cover width 60, thickness 0.25: 15 pt spines, 1.5 pt apart.
        let books = (0..<10).map { book("\($0)", thickness: 0.25) }
        let layout = WidgetShelfLayout(books: books, totalCount: 10, style: .spines,
                                       rowCount: 2, rowWidth: 50, bookHeight: 90)
        // 15 + 1.5 + 15 + 1.5 + 15 = 48 fits a row; a fourth doesn't. The
        // last row gives up 34 pt to the "+N" badge, leaving room for one.
        #expect(layout.rows.map(\.count) == [3, 1])
        #expect(layout.rows.joined().map(\.book.title) == ["0", "1", "2", "3"])
        #expect(layout.overflow == 6)
    }

    @Test func overflowLeavesRoomForBadge() {
        let books = (0..<10).map { _ in book(thickness: 0.25) }
        let layout = WidgetShelfLayout(books: books, totalCount: 10, style: .spines,
                                       rowCount: 1, rowWidth: 80, bookHeight: 90)
        let used = layout.rows[0].reduce(0) { $0 + $1.width } + Double(layout.rows[0].count - 1) * WidgetShelfLayout.spacing
        #expect(used <= 80 - WidgetShelfLayout.overflowBadgeWidth)
        #expect(layout.overflow == 10 - layout.rows[0].count)
    }

    @Test func coversDontGiveUpABookForTheBadge() {
        let books = (0..<10).map { _ in book() }
        // Covers are 60 wide at height 90: four fit in 250 with room to spare,
        // but not with 34 more kept for the badge.
        let layout = WidgetShelfLayout(books: books, totalCount: 10, style: .covers,
                                       rowCount: 1, rowWidth: 250, bookHeight: 90)
        #expect(layout.rows[0].count == 4)
        #expect(layout.overflow == 6)
    }

    @Test func noBadgeWhenEverythingFits() {
        let books = (0..<3).map { _ in book(thickness: 0.25) }
        let layout = WidgetShelfLayout(books: books, totalCount: 3, style: .spines,
                                       rowCount: 1, rowWidth: 50, bookHeight: 90)
        #expect(layout.overflow == 0)
        #expect(layout.rows[0].count == 3)
    }

    @Test func booksPastTheSnapshotCapCountAsOverflow() {
        let layout = WidgetShelfLayout(books: [book()], totalCount: 500, style: .covers,
                                       rowCount: 1, rowWidth: 300, bookHeight: 90)
        #expect(layout.overflow == 499)
    }

    @Test func thinSpinesHaveAMinimumWidth() {
        let width = WidgetShelfLayout.width(of: book(thickness: 0.01), style: .spines, bookHeight: 90)
        #expect(width == WidgetShelfLayout.minimumSpineWidth)
        #expect(WidgetShelfLayout.width(of: book(), style: .covers, bookHeight: 90) == 60)
    }

    @Test func sizeScaleChangesHeightAndWidthAndIsClamped() {
        var tall = book(thickness: 0.25)
        tall.sizeScale = 1.1
        #expect(abs(WidgetShelfLayout.height(of: tall, bookHeight: 90) - 99) < 0.0001)
        #expect(abs(WidgetShelfLayout.width(of: tall, style: .covers, bookHeight: 90) - 66) < 0.0001)
        tall.sizeScale = 3
        #expect(WidgetShelfLayout.height(of: tall, bookHeight: 90) == 90 * WidgetShelfLayout.maxScale)
        tall.sizeScale = .nan
        #expect(WidgetShelfLayout.height(of: tall, bookHeight: 90) == 90)
    }

    @Test func emptyRowsStillExist() {
        let layout = WidgetShelfLayout(books: [book()], totalCount: 1, style: .covers,
                                       rowCount: 3, rowWidth: 300, bookHeight: 90)
        #expect(layout.rows.map(\.count) == [1, 0, 0])
    }
}

@MainActor
struct WidgetSnapshotWriterTests {
    private func makeWriter(store: WidgetStore, container: ModelContainer, reloads: Counter,
                            style: WidgetSnapshot.ShelfStyle = .spines) -> WidgetSnapshotWriter {
        WidgetSnapshotWriter(
            container: container,
            store: store,
            coverInfo: { _ in
                WidgetSnapshotWriter.CoverInfo(thickness: 0.2, baseColor: RGBAColor(red: 1, green: 0, blue: 0),
                                               spineColor: RGBAColor(red: 0, green: 0, blue: 1))
            },
            shelfStyle: { style },
            reload: { reloads.value += 1 }
        )
    }

    @MainActor final class Counter { var value = 0 }

    private func tempStore() -> WidgetStore {
        WidgetStore(root: FileManager.default.temporaryDirectory.appending(path: "widgets-\(UUID().uuidString)"))
    }

    private func addBook(_ title: String, order: Int, to context: ModelContext) -> Book {
        let book = Book(relativeFilePath: "\(title).epub", contentHash: title, format: .epub, title: title,
                        authors: ["Author"], shelfOrder: order)
        context.insert(book)
        return book
    }

    @Test func writesShelfOrderCurrentBookAndStyle() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let context = container.mainContext
        _ = addBook("Second", order: 1, to: context)
        let first = addBook("First", order: 0, to: context)
        let reading = addBook("Reading", order: 2, to: context)
        reading.recordReadingPosition(locatorJSON: "{}", progression: 0.42)
        first.recordReadingPosition(locatorJSON: "{}", progression: 1, at: .now.addingTimeInterval(60))
        try context.save()

        let store = tempStore()
        let reloads = Counter()
        await makeWriter(store: store, container: container, reloads: reloads, style: .covers).refresh()

        let snapshot = try #require(store.load())
        #expect(snapshot.books.map(\.title) == ["First", "Second", "Reading"])
        #expect(snapshot.current?.title == "Reading")
        #expect(snapshot.current?.percent == 42)
        #expect(snapshot.shelfStyle == .covers)
        #expect(snapshot.totalBookCount == 3)
        #expect(snapshot.books[0].thickness == 0.2)
        #expect(snapshot.books[0].spineColor.blue == 1)
        #expect(reloads.value == 1)
    }

    @Test func doesNotReloadWhenNothingChanged() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        _ = addBook("Only", order: 0, to: container.mainContext)
        try container.mainContext.save()
        let store = tempStore()
        let reloads = Counter()
        let writer = makeWriter(store: store, container: container, reloads: reloads)

        await writer.refresh()
        await writer.refresh()
        #expect(reloads.value == 1)

        let book = try #require(try container.mainContext.fetch(FetchDescriptor<Book>()).first)
        book.recordReadingPosition(locatorJSON: "{}", progression: 0.1)
        await writer.refresh()
        #expect(reloads.value == 2)
        #expect(store.load()?.current?.title == "Only")
    }

    @Test func deletedBooksLeaveTheSnapshot() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let gone = addBook("Gone", order: 0, to: context)
        _ = addBook("Kept", order: 1, to: context)
        try context.save()
        let store = tempStore()
        let writer = makeWriter(store: store, container: container, reloads: Counter())
        await writer.refresh()
        context.delete(gone)
        try context.save()
        await writer.refresh()
        #expect(store.load()?.books.map(\.title) == ["Kept"])
    }

    @Test func imagesAreDownsizedSkippedWhenFreshAndPruned() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "widget-images-\(UUID().uuidString)")
        let sourceFolder = FileManager.default.temporaryDirectory.appending(path: "widget-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let source = sourceFolder.appending(path: "front.jpg")
        let big = UIGraphicsImageRenderer(size: CGSize(width: 1400, height: 2100)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1400, height: 2100))
        }
        try #require(big.jpegData(compressionQuality: 0.8)).write(to: source)

        let destination = folder.appending(path: "a-front.jpg")
        let job = WidgetSnapshotWriter.ImageJob(source: source, destination: destination, maxPixels: 330)
        #expect(WidgetSnapshotWriter.writeImages([job], into: folder))
        let written = try #require(UIImage(contentsOfFile: destination.path()))
        #expect(max(written.size.width * written.scale, written.size.height * written.scale) <= 330)

        // Up to date: nothing to do.
        #expect(!WidgetSnapshotWriter.writeImages([job], into: folder))

        // No longer wanted: removed.
        #expect(WidgetSnapshotWriter.writeImages([], into: folder))
        #expect(!FileManager.default.fileExists(atPath: destination.path()))
    }
}
