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

    public init(id: UUID, thickness: Double) {
        self.id = id
        self.thickness = thickness
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

    public var bookWidth: Float { bookHeight * Float(CoverDesign.frontAspectRatio) }
    public var rowHeight: Float { bookHeight + headroom + boardThickness }
    /// How deep the boards are: a book standing spine-out, plus a lip.
    public var shelfDepth: Float { bookWidth + 0.025 }

    /// Width of a book along the shelf.
    public func footprint(of book: ShelfBookSpec, mode: ShelfDisplayMode) -> Float {
        switch mode {
        case .spines: max(bookWidth * Float(book.thickness), 0.006)
        case .covers: bookWidth
        }
    }

    /// Thickness of a book's block, front cover to back cover.
    public func depth(of book: ShelfBookSpec) -> Float {
        max(bookWidth * Float(book.thickness), 0.006)
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

    /// `minimumCaseRows` is how many shelves fill the screen; see
    /// `ShelfLayout.rowsToFill(height:metrics:)`.
    public init(books: [ShelfBookSpec], mode: ShelfDisplayMode, shelfWidth: Float, minimumCaseRows: Int = 1, metrics: ShelfMetrics = ShelfMetrics()) {
        self.metrics = metrics
        self.mode = mode
        let width = max(shelfWidth, metrics.bookWidth + 2 * metrics.sideMargin)
        self.shelfWidth = width
        let usable = width - 2 * metrics.sideMargin
        let left = -width / 2 + metrics.sideMargin

        var slots: [Slot] = []
        slots.reserveCapacity(books.count)
        var row = 0
        var cursor: Float = 0
        // Face-out books spread evenly across the shelf; spines pack tight.
        let gap: Float
        switch mode {
        case .spines:
            gap = metrics.bookGap
        case .covers:
            let perRow = Self.perRow(usable, metrics)
            gap = max(metrics.coverGap, (usable - perRow * metrics.bookWidth) / perRow)
        }
        for (index, book) in books.enumerated() {
            let footprint = metrics.footprint(of: book, mode: mode)
            if cursor > 0, cursor + footprint > usable + 0.0001 {
                row += 1
                cursor = 0
            }
            let x = left + cursor + footprint / 2
            slots.append(Slot(id: book.id, index: index, row: row, x: x, baseY: Self.baseY(row: row, metrics: metrics), footprint: footprint))
            cursor += footprint + gap
        }
        self.slots = slots
        self.rowCount = books.isEmpty ? 1 : row + 1
        self.caseRowCount = max(rowCount + 1, minimumCaseRows)
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
    public var contentTop: Float { metrics.bookHeight + metrics.headroom }
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
        let fromTop = (metrics.bookHeight + metrics.headroom) - y
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
                && y >= slot.baseY && y <= slot.baseY + metrics.bookHeight
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
