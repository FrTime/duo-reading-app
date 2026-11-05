import CoreGraphics

/// Where the page and the reader's controls go, for every iPhone Duo pose.
///
/// Decided from the reader's own size and the fold (the "division" reserved
/// region), never from orientation or device type, as Apple's Duo guidance asks.
///
/// - Closed, or open flat: one page, or two side by side when the window is
///   wide enough. The fold is inactive when the Duo is fully open, so a spread
///   runs straight across the middle.
/// - Half-folded like a book (the fold runs top to bottom): one page on each
///   side, with the crease kept clear of text.
/// - Half-folded like a laptop (the fold runs side to side): the page sits on
///   the upper half and the controls on the lower half, which rests on the table.
public struct ReaderLayout: Equatable, Sendable {
    public enum Pose: Equatable, Sendable {
        case flat
        case book
        case tabletop
    }

    public var pose: Pose
    /// Where the page view goes, in the reader's coordinates.
    public var pageFrame: CGRect
    /// Space for controls that sit beside the page instead of over it: the
    /// lower half in tabletop, or the empty side in book pose when only one
    /// page is shown. Nil when the controls overlay the page.
    public var controlsFrame: CGRect?
    /// Pages shown side by side, 1 or 2.
    public var columns: Int
    /// Width of the fold inside `pageFrame` that text must stay out of.
    public var foldWidth: CGFloat

    /// Minimum window width for an automatic two-page spread.
    public static let automaticSpreadMinWidth: CGFloat = 600
    /// Below this width two pages are too narrow to read, even when asked for.
    public static let forcedSpreadMinWidth: CGFloat = 480

    public init(pose: Pose, pageFrame: CGRect, controlsFrame: CGRect?, columns: Int, foldWidth: CGFloat) {
        self.pose = pose
        self.pageFrame = pageFrame
        self.controlsFrame = controlsFrame
        self.columns = columns
        self.foldWidth = foldWidth
    }

    /// Works out the layout.
    ///
    /// - Parameters:
    ///   - size: The reader's size.
    ///   - fold: The frame of the active division region, if any, in the
    ///     reader's coordinates.
    ///   - spread: The user's one-or-two-pages preference.
    ///   - flow: Pages or scroll.
    public static func resolve(size: CGSize, fold: CGRect?, spread: ReaderSpread, flow: ReaderFlow) -> ReaderLayout {
        let bounds = CGRect(origin: .zero, size: size)

        guard let fold = fold?.intersection(bounds), !fold.isNull, fold.width > 0 || fold.height > 0 else {
            return ReaderLayout(
                pose: .flat,
                pageFrame: bounds,
                controlsFrame: nil,
                columns: columns(for: size, spread: spread, flow: flow),
                foldWidth: 0
            )
        }

        if fold.height >= fold.width {
            // Book: the fold runs top to bottom.
            let left = CGRect(x: 0, y: 0, width: fold.minX, height: size.height)
            let right = CGRect(x: fold.maxX, y: 0, width: max(0, size.width - fold.maxX), height: size.height)
            if flow == .paged, spread != .single {
                // Readium splits a spread down its middle, so centre the page
                // view on the fold, even when the fold is off centre.
                let half = min(fold.midX, size.width - fold.midX)
                let spread = CGRect(x: fold.midX - half, y: 0, width: 2 * half, height: size.height)
                return ReaderLayout(pose: .book, pageFrame: spread, controlsFrame: nil, columns: 2, foldWidth: fold.width)
            }
            // One page (scrolling, or the reader asked for one): it goes on
            // the left half and the controls on the right. Left, not leading,
            // because the halves are physical screen panels.
            return ReaderLayout(pose: .book, pageFrame: left, controlsFrame: right, columns: 1, foldWidth: 0)
        }

        // Tabletop: the fold runs side to side.
        let top = CGRect(x: 0, y: 0, width: size.width, height: fold.minY)
        let bottom = CGRect(x: 0, y: fold.maxY, width: size.width, height: max(0, size.height - fold.maxY))
        return ReaderLayout(
            pose: .tabletop,
            pageFrame: top,
            controlsFrame: bottom,
            columns: columns(for: top.size, spread: spread, flow: flow),
            foldWidth: 0
        )
    }

    static func columns(for size: CGSize, spread: ReaderSpread, flow: ReaderFlow) -> Int {
        guard flow == .paged else { return 1 }
        switch spread {
        case .single:
            return 1
        case .double:
            return size.width >= forcedSpreadMinWidth ? 2 : 1
        case .automatic:
            return size.width > size.height && size.width >= automaticSpreadMinWidth ? 2 : 1
        }
    }

    /// How much to add to the margin factor so the gap between two pages
    /// clears the fold.
    ///
    /// Each page has `gutter × margins` of padding on both sides, so the gap
    /// between two pages is `2 × gutter × margins`. To clear a fold of width
    /// `w` plus the usual margin on each side, add `w / (2 × gutter)`.
    public func extraMarginFactor(gutter: CGFloat) -> Double {
        guard columns == 2, foldWidth > 0, gutter > 0 else { return 0 }
        return Double(foldWidth / (2 * gutter))
    }
}
