import CoreGraphics
import Foundation
import simd

/// How books stand on the shelf.
public enum ShelfDisplayMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Spine out, like a real bookcase. Fits many books per shelf.
    case spines
    /// Face out, like a shop display.
    case covers

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .spines: String(localized: "Spines")
        case .covers: String(localized: "Covers")
        }
    }
}

/// What the layout needs to know about one book.
public struct ShelfBookSpec: Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Spine width as a fraction of the cover's width (`CoverDesign.thickness`).
    public var thickness: Double
    /// Size relative to a standard book (`CoverDesign.sizeScale`).
    public var heightScale: Double

    public init(id: UUID, thickness: Double, heightScale: Double = 1) {
        self.id = id
        self.thickness = thickness
        self.heightScale = heightScale
    }

    var scale: Float {
        Float(min(max(heightScale, CoverDesign.heightScaleRange.lowerBound), CoverDesign.heightScaleRange.upperBound))
    }
}

/// Fixed sizes of the bookcase, in scene units (roughly metres).
public struct ShelfMetrics: Hashable, Sendable {
    public var bookHeight: Float = 0.24
    public var bookGap: Float = 0.003
    /// Smallest space between face-out books, so they don't read as tiles.
    public var coverGap: Float = 0.01
    /// Space above the books on each shelf.
    public var headroom: Float = 0.055
    public var boardThickness: Float = 0.018
    /// Margin between the outermost books and the sides of the case.
    public var sideMargin: Float = 0.02

    public init() {}

    /// A standard book's cover width. Each book scales this and `bookHeight`.
    public var bookWidth: Float { bookHeight * Float(CoverDesign.frontAspectRatio) }
    /// The tallest a book can be, which sets the space between shelves.
    public var maxBookHeight: Float { bookHeight * Float(CoverDesign.heightScaleRange.upperBound) }
    public var rowHeight: Float { maxBookHeight + headroom + boardThickness }
    /// How deep the boards are: the widest book standing spine-out, plus a lip.
    public var shelfDepth: Float { bookWidth * Float(CoverDesign.heightScaleRange.upperBound) + 0.025 }

    public func height(of book: ShelfBookSpec) -> Float { bookHeight * book.scale }
    public func width(of book: ShelfBookSpec) -> Float { bookWidth * book.scale }

    /// Width of a book along the shelf.
    public func footprint(of book: ShelfBookSpec, mode: ShelfDisplayMode) -> Float {
        switch mode {
        case .spines: depth(of: book)
        case .covers: width(of: book)
        }
    }

    /// Thickness of a book's block, front cover to back cover.
    public func depth(of book: ShelfBookSpec) -> Float {
        max(width(of: book) * Float(book.thickness), 0.006)
    }
}

/// Where every book sits. Books fill each shelf left to right, in order,
/// and wrap to the next shelf down. Pure geometry, so it's unit-tested.
public struct ShelfLayout: Sendable {
    public struct Slot: Hashable, Sendable {
        public var id: UUID
        public var index: Int
        public var row: Int
        /// Centre of the book along the shelf.
        public var x: Float
        /// Top surface of the board the book stands on.
        public var baseY: Float
        /// Width along the shelf.
        public var footprint: Float
        public var height: Float
    }

    public let metrics: ShelfMetrics
    public let mode: ShelfDisplayMode
    public let shelfWidth: Float
    public let slots: [Slot]
    /// Shelves that hold books.
    public let rowCount: Int
    /// Shelves the bookcase is built with: the ones holding books, one
    /// empty one below so scrolling to the end never shows bare wall, and
    /// enough to fill the screen when there are few books.
    public let caseRowCount: Int

    /// Where an upright divides each shelf into two bays, in scene x, if
    /// anywhere. On the open Duo it stands over the hinge.
    public let divider: ClosedRange<Float>?

    /// `minimumCaseRows` is how many shelves fill the screen; see
    /// `ShelfLayout.rowsToFill(height:metrics:)`. `divider` is the span of
    /// an upright (the fold); books never stand across it.
    public init(
        books: [ShelfBookSpec],
        mode: ShelfDisplayMode,
        shelfWidth: Float,
        minimumCaseRows: Int = 1,
        divider: ClosedRange<Float>? = nil,
        metrics: ShelfMetrics = ShelfMetrics()
    ) {
        self.metrics = metrics
        self.mode = mode
        let width = max(shelfWidth, metrics.bookWidth + 2 * metrics.sideMargin)
        self.shelfWidth = width
        let left = -width / 2 + metrics.sideMargin
        let right = width / 2 - metrics.sideMargin

        // The bays books stand in. A divider only splits the case when both
        // bays can hold a face-out book; otherwise it's ignored.
        var bays: [ClosedRange<Float>] = [left...right]
        var usedDivider: ClosedRange<Float>?
        if let divider {
            let thick = max(divider.upperBound - divider.lowerBound, metrics.boardThickness)
            let mid = (divider.lowerBound + divider.upperBound) / 2
            let span = (mid - thick / 2)...(mid + thick / 2)
            // Check the widths before forming ranges: a range with its ends
            // the wrong way round traps.
            let leftEnd = span.lowerBound - metrics.sideMargin
            let rightStart = span.upperBound + metrics.sideMargin
            let minimum = metrics.bookWidth * Float(CoverDesign.heightScaleRange.upperBound)
            if leftEnd - left >= minimum, right - rightStart >= minimum {
                bays = [left...leftEnd, rightStart...right]
                usedDivider = span
            }
        }
        self.divider = usedDivider

        // Face-out books spread evenly across each bay; spines pack tight.
        let gaps: [Float] = bays.map { bay in
            switch mode {
            case .spines:
                return metrics.bookGap
            case .covers:
                let usable = bay.upperBound - bay.lowerBound
                let perRow = Self.perRow(usable, metrics)
                return max(metrics.coverGap, (usable - perRow * metrics.bookWidth) / perRow)
            }
        }

        var slots: [Slot] = []
        slots.reserveCapacity(books.count)
        var row = 0
        var bay = 0
        var cursor: Float = 0
        for (index, book) in books.enumerated() {
            let footprint = metrics.footprint(of: book, mode: mode)
            while cursor > 0, cursor + footprint > bays[bay].upperBound - bays[bay].lowerBound + 0.0001 {
                cursor = 0
                bay += 1
                if bay == bays.count {
                    bay = 0
                    row += 1
                }
            }
            let x = bays[bay].lowerBound + cursor + footprint / 2
            slots.append(Slot(
                id: book.id, index: index, row: row, x: x,
                baseY: Self.baseY(row: row, metrics: metrics),
                footprint: footprint, height: metrics.height(of: book)
            ))
            cursor += footprint + gaps[bay]
        }
        self.slots = slots
        self.rowCount = books.isEmpty ? 1 : row + 1
        self.caseRowCount = max(rowCount + 1, minimumCaseRows)
    }

    /// The scene box a book fills as it stands on the shelf: spine out, its
    /// cover width runs back into the case; face out, its thickness does.
    public func box(of slot: Slot, spec: ShelfBookSpec) -> (low: SIMD3<Float>, high: SIMD3<Float>) {
        let back: Float = switch mode {
        case .spines: metrics.width(of: spec) + 0.006
        case .covers: metrics.depth(of: spec) + 0.01
        }
        return (
            SIMD3(slot.x - slot.footprint / 2, slot.baseY, -back),
            SIMD3(slot.x + slot.footprint / 2, slot.baseY + slot.height, 0)
        )
    }

    /// The book under a screen point: the front face under it if any;
    /// otherwise any book whose on-screen shape (including the sides that
    /// perspective shows, as on a lone book at the end of a shelf) or a
    /// finger-sized strip around a thin spine contains it, nearest first.
    public func book(atScreen point: CGPoint, camera: ShelfCamera, specs: (UUID) -> ShelfBookSpec, minimumWidth: CGFloat = 44) -> UUID? {
        let front = camera.scenePoint(for: point, atZ: -0.01)
        if let exact = book(atX: front.x, y: front.y) { return exact }
        var best: (id: UUID, distance: CGFloat)?
        for slot in slots {
            let (low, high) = box(of: slot, spec: specs(slot.id))
            var rect = camera.screenBounds(from: low, to: high)
            if rect.width < minimumWidth {
                rect = rect.insetBy(dx: (rect.width - minimumWidth) / 2, dy: 0)
            }
            guard rect.contains(point) else { continue }
            let distance = abs(rect.midX - point.x)
            if best == nil || distance < best!.distance {
                best = (slot.id, distance)
            }
        }
        return best?.id
    }

    /// `x` moved just enough that something `halfExtent` wide either side of
    /// it stays inside the case, and inside `visibleHalfWidth` of the centre
    /// when given (things nearer the camera see less of the scene).
    public func clampedX(_ x: Float, halfExtent: Float, visibleHalfWidth: Float? = nil) -> Float {
        let limit = min(shelfWidth / 2, visibleHalfWidth ?? .infinity) - halfExtent
        guard limit > 0 else { return 0 }
        return min(max(x, -limit), limit)
    }

    /// Shelves needed to cover a visible height, plus one spare.
    public static func rowsToFill(height: Float, metrics: ShelfMetrics = ShelfMetrics()) -> Int {
        Int((max(height, 0) / metrics.rowHeight).rounded(.up)) + 1
    }

    /// Whole face-out books that fit on a shelf.
    private static func perRow(_ usable: Float, _ metrics: ShelfMetrics) -> Float {
        max(((usable + metrics.coverGap) / (metrics.bookWidth + metrics.coverGap)).rounded(.down), 1)
    }

    public static func baseY(row: Int, metrics: ShelfMetrics) -> Float {
        -Float(row) * metrics.rowHeight
    }

    /// Top of the bookcase (the space above the first shelf's books).
    public var contentTop: Float { metrics.maxBookHeight + metrics.headroom }
    /// Bottom of the last board.
    public var contentBottom: Float { Self.baseY(row: rowCount - 1, metrics: metrics) - metrics.boardThickness }
    public var contentHeight: Float { contentTop - contentBottom }
    /// Bottom of the bookcase's last (possibly empty) board.
    public var caseBottom: Float { Self.baseY(row: caseRowCount - 1, metrics: metrics) - metrics.boardThickness }

    public func slot(for id: UUID) -> Slot? {
        slots.first { $0.id == id }
    }

    /// The shelf a height falls on, clamped to the shelves in the case.
    public func row(atY y: Float) -> Int {
        let fromTop = (metrics.maxBookHeight + metrics.headroom) - y
        let row = Int((fromTop / metrics.rowHeight).rounded(.down))
        return min(max(row, 0), caseRowCount - 1)
    }

    /// Where a book dropped at (x, y) would go, as an index into the order
    /// without the dragged book. Lay this layout out *without* the dragged book.
    public func insertionIndex(x: Float, y: Float) -> Int {
        guard !slots.isEmpty else { return 0 }
        let row = row(atY: y)
        let inRow = slots.filter { $0.row == row }
        guard let first = inRow.first, let last = inRow.last else {
            // Below the last book: append.
            return slots.count
        }
        if let next = inRow.first(where: { x < $0.x }) {
            return next.index
        }
        return x < first.x ? first.index : last.index + 1
    }

    /// The book whose front-facing rectangle contains (x, y), if any.
    public func book(atX x: Float, y: Float) -> UUID? {
        slots.first { slot in
            abs(x - slot.x) <= slot.footprint / 2 + metrics.bookGap / 2
                && y >= slot.baseY && y <= slot.baseY + slot.height
        }?.id
    }
}

extension Array where Element == UUID {
    /// The order after moving `id` to `index` (an index into the order without it).
    public func moving(_ id: UUID, to index: Int) -> [UUID] {
        var result = filter { $0 != id }
        guard result.count < count else { return self }
        result.insert(id, at: Swift.min(Swift.max(index, 0), result.count))
        return result
    }
}
