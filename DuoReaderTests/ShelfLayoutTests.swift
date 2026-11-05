import CoreGraphics
import Foundation
import Testing
@testable import DuoReader

struct ShelfLayoutTests {
    let metrics = ShelfMetrics()

    func books(_ count: Int, thickness: Double = 0.12) -> [ShelfBookSpec] {
        (0..<count).map { _ in ShelfBookSpec(id: UUID(), thickness: thickness) }
    }

    @Test func keepsOrderLeftToRight() {
        let specs = books(5)
        let layout = ShelfLayout(books: specs, mode: .spines, shelfWidth: 1)
        #expect(layout.slots.map(\.id) == specs.map(\.id))
        #expect(layout.rowCount == 1)
        let xs = layout.slots.map(\.x)
        #expect(xs == xs.sorted())
        #expect(layout.slots.allSatisfy { $0.baseY == 0 })
    }

    @Test func wrapsToTheNextShelf() {
        let layout = ShelfLayout(books: books(60), mode: .spines, shelfWidth: 0.5)
        #expect(layout.rowCount > 1)
        let usable = layout.shelfWidth - 2 * metrics.sideMargin
        for row in 0..<layout.rowCount {
            let inRow = layout.slots.filter { $0.row == row }
            #expect(!inRow.isEmpty)
            let left = inRow.map { $0.x - $0.footprint / 2 }.min()!
            let right = inRow.map { $0.x + $0.footprint / 2 }.max()!
            #expect(right - left <= usable + 0.0001, "row \(row) overflows")
            #expect(inRow.allSatisfy { $0.baseY == ShelfLayout.baseY(row: row, metrics: metrics) })
        }
    }

    @Test func widerScreensHoldMoreBooksPerShelf() {
        let specs = books(80)
        let folded = ShelfLayout(books: specs, mode: .spines, shelfWidth: 0.6)
        let open = ShelfLayout(books: specs, mode: .spines, shelfWidth: 1.3)
        #expect(open.rowCount < folded.rowCount)
    }

    @Test func coversModeSpacesBooksEvenly() {
        let layout = ShelfLayout(books: books(7), mode: .covers, shelfWidth: 0.7)
        let firstRow = layout.slots.filter { $0.row == 0 }
        #expect(firstRow.count >= 3)
        #expect(firstRow.allSatisfy { $0.footprint == metrics.bookWidth })
        let gaps = zip(firstRow, firstRow.dropFirst()).map { $1.x - $0.x }
        #expect(gaps.allSatisfy { abs($0 - gaps[0]) < 0.0001 })
    }

    @Test func coversModeLeavesAGapBetweenBooks() {
        let layout = ShelfLayout(books: books(20), mode: .covers, shelfWidth: 1.3)
        let firstRow = layout.slots.filter { $0.row == 0 }
        for (left, right) in zip(firstRow, firstRow.dropFirst()) {
            #expect((right.x - right.footprint / 2) - (left.x + left.footprint / 2) >= metrics.coverGap - 0.0001)
        }
    }

    @Test func caseFillsTheScreenAndHasASpareShelf() {
        let few = ShelfLayout(books: books(3), mode: .spines, shelfWidth: 1, minimumCaseRows: 4)
        #expect(few.rowCount == 1)
        #expect(few.caseRowCount == 4)
        #expect(few.caseBottom < few.contentBottom)
        let many = ShelfLayout(books: books(200), mode: .spines, shelfWidth: 0.5, minimumCaseRows: 2)
        #expect(many.caseRowCount == many.rowCount + 1)
        // Empty shelves in the case still accept a dropped book, at the end.
        #expect(few.insertionIndex(x: 0, y: ShelfLayout.baseY(row: 3, metrics: metrics) + 0.1) == 3)
    }

    @Test func rowsToFillCoverTheHeight() {
        let rows = ShelfLayout.rowsToFill(height: 1.0, metrics: metrics)
        #expect(Float(rows - 1) * metrics.rowHeight >= 1.0)
        #expect(ShelfLayout.rowsToFill(height: 0, metrics: metrics) == 1)
    }

    @Test(arguments: [ShelfDisplayMode.spines, .covers])
    func noBookStandsAcrossTheFold(mode: ShelfDisplayMode) throws {
        let fold: ClosedRange<Float> = -0.01...0.01
        let layout = ShelfLayout(books: books(80), mode: mode, shelfWidth: 1.3, divider: fold)
        let divider = try #require(layout.divider)
        #expect(divider.lowerBound <= fold.lowerBound && divider.upperBound >= fold.upperBound)
        for slot in layout.slots {
            let left = slot.x - slot.footprint / 2
            let right = slot.x + slot.footprint / 2
            #expect(right <= divider.lowerBound || left >= divider.upperBound)
        }
        // Both bays are used on the first shelf, left one first.
        let firstRow = layout.slots.filter { $0.row == 0 }
        #expect(firstRow.contains { $0.x < divider.lowerBound })
        #expect(firstRow.contains { $0.x > divider.upperBound })
        #expect(firstRow.map(\.x) == firstRow.map(\.x).sorted())
    }

    @Test func ignoresAFoldWhenABayWouldBeTooNarrow() {
        let layout = ShelfLayout(books: books(5), mode: .spines, shelfWidth: 0.3, divider: 0.1...0.11)
        #expect(layout.divider == nil)
    }

    @Test func pulledOutBooksStayInsideTheCase() {
        let layout = ShelfLayout(books: books(30), mode: .spines, shelfWidth: 1)
        let first = layout.slots.first!
        let x = layout.clampedX(first.x, halfExtent: 0.12)
        #expect(x - 0.12 >= -layout.shelfWidth / 2 - 1e-6)
        #expect(layout.clampedX(0, halfExtent: 0.12) == 0)
        #expect(layout.clampedX(0.49, halfExtent: 0.12) <= layout.shelfWidth / 2 - 0.12 + 1e-6)
        #expect(layout.clampedX(0.3, halfExtent: 2) == 0)
    }

    @Test func booksGrowWithLargerText() {
        #expect(ShelfCamera.zoom(forTextScale: 1) == 1)
        #expect(ShelfCamera.zoom(forTextScale: 0.8) == 1)
        #expect(ShelfCamera.zoom(forTextScale: 2) == 1.5)
        #expect(ShelfCamera.zoom(forTextScale: 4) == 1.5)
        let standard = ShelfCamera(viewSize: CGSize(width: 400, height: 700))
        let zoomed = ShelfCamera(viewSize: CGSize(width: 400, height: 700), zoom: 1.5)
        #expect(zoomed.halfWidth < standard.halfWidth)
        let top = zoomed.screenPoint(for: SIMD3(0, metrics.bookHeight, 0))
        let bottom = zoomed.screenPoint(for: SIMD3(0, 0, 0))
        #expect(abs((bottom.y - top.y) - CGFloat(metrics.bookHeight * zoomed.scale)) < 0.5)
    }

    @Test func thickerBooksTakeMoreRoom() {
        let thin = ShelfBookSpec(id: UUID(), thickness: 0.05)
        let thick = ShelfBookSpec(id: UUID(), thickness: 0.3)
        #expect(metrics.footprint(of: thick, mode: .spines) > metrics.footprint(of: thin, mode: .spines))
        #expect(metrics.footprint(of: thick, mode: .covers) == metrics.footprint(of: thin, mode: .covers))
    }

    @Test func emptyShelfHasOneRow() {
        let layout = ShelfLayout(books: [], mode: .spines, shelfWidth: 1)
        #expect(layout.rowCount == 1)
        #expect(layout.insertionIndex(x: 0, y: 0.1) == 0)
        #expect(layout.contentHeight > 0)
    }

    @Test func findsTheBookUnderAPoint() throws {
        let specs = books(10)
        let layout = ShelfLayout(books: specs, mode: .spines, shelfWidth: 1)
        let third = try #require(layout.slots.dropFirst(2).first)
        #expect(layout.book(atX: third.x, y: third.baseY + 0.1) == third.id)
        #expect(layout.book(atX: third.x, y: third.baseY + metrics.bookHeight + 0.02) == nil)
        #expect(layout.book(atX: 0.49, y: 0.1) == nil)
    }

    @Test func insertionIndexFollowsTheFinger() throws {
        let specs = books(10)
        let layout = ShelfLayout(books: specs, mode: .spines, shelfWidth: 1)
        let slots = layout.slots
        let y = metrics.bookHeight / 2
        #expect(layout.insertionIndex(x: slots[0].x - 0.05, y: y) == 0)
        #expect(layout.insertionIndex(x: (slots[3].x + slots[4].x) / 2, y: y) == 4)
        #expect(layout.insertionIndex(x: 0.45, y: y) == 10)
    }

    @Test func insertionOnALowerShelf() {
        let layout = ShelfLayout(books: books(60), mode: .spines, shelfWidth: 0.5)
        let secondRow = layout.slots.filter { $0.row == 1 }
        let y = ShelfLayout.baseY(row: 1, metrics: metrics) + 0.1
        #expect(layout.insertionIndex(x: -1, y: y) == secondRow.first?.index)
        // Far below the last shelf still lands on the last shelf.
        let last = layout.slots.last!
        #expect(layout.insertionIndex(x: 1, y: -100) == last.index + 1)
        #expect(layout.row(atY: 100) == 0)
    }

    @Test func movingReordersIDs() {
        let ids = (0..<4).map { _ in UUID() }
        #expect(ids.moving(ids[0], to: 3) == [ids[1], ids[2], ids[3], ids[0]])
        #expect(ids.moving(ids[3], to: 0) == [ids[3], ids[0], ids[1], ids[2]])
        #expect(ids.moving(ids[1], to: 1) == ids)
        #expect(ids.moving(ids[1], to: 99) == [ids[0], ids[2], ids[3], ids[1]])
        #expect(ids.moving(ids[1], to: -5) == [ids[1], ids[0], ids[2], ids[3]])
        #expect(ids.moving(UUID(), to: 0) == ids)
    }
}

struct ShelfCameraTests {
    @Test func bookIsTheSameSizeOnEveryScreen() {
        let folded = ShelfCamera(viewSize: CGSize(width: 400, height: 700))
        let open = ShelfCamera(viewSize: CGSize(width: 900, height: 700))
        let metrics = ShelfMetrics()
        for camera in [folded, open] {
            let top = camera.screenPoint(for: SIMD3(0, metrics.bookHeight, 0))
            let bottom = camera.screenPoint(for: SIMD3(0, 0, 0))
            #expect(abs((bottom.y - top.y) - CGFloat(metrics.bookHeight * ShelfCamera.pointsPerUnit)) < 0.5)
        }
        #expect(open.shelfWidth > folded.shelfWidth * 2)
    }

    @Test(arguments: [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 350), CGPoint(x: 390, y: 600)])
    func screenAndSceneRoundTrip(_ point: CGPoint) {
        let camera = ShelfCamera(viewSize: CGSize(width: 400, height: 700), centerY: -0.3)
        for z: Float in [0, -0.01, 0.06] {
            let scene = camera.scenePoint(for: point, atZ: z)
            let back = camera.screenPoint(for: SIMD3(scene.x, scene.y, z))
            #expect(abs(back.x - point.x) < 0.01)
            #expect(abs(back.y - point.y) < 0.01)
        }
    }

    @Test func centreOfTheScreenIsTheCameraTarget() {
        let camera = ShelfCamera(viewSize: CGSize(width: 400, height: 700), centerY: 0.42)
        let centre = camera.scenePoint(for: CGPoint(x: 200, y: 350))
        #expect(abs(centre.x) < 0.0001)
        #expect(abs(centre.y - 0.42) < 0.0001)
    }

    @Test func scrollRangeKeepsShortShelvesAtTheTop() {
        let range = ShelfCamera.scrollRange(top: 0.3, bottom: 0, halfHeight: 0.6)
        #expect(range.lowerBound == range.upperBound)
        let tall = ShelfCamera.scrollRange(top: 0.3, bottom: -3, halfHeight: 0.6)
        #expect(tall.lowerBound < tall.upperBound)
        #expect(abs(tall.upperBound - (0.3 + 0.03 - 0.6)) < 1e-5)
    }
}
