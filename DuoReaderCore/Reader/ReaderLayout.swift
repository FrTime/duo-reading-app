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

    /// Space the system keeps on the left and right, such as the Duo's
    /// status rail. The page and controls stay inside it.
    public struct SideInsets: Equatable, Sendable {
        public var left: CGFloat
        public var right: CGFloat

        public init(left: CGFloat = 0, right: CGFloat = 0) {
            self.left = left
            self.right = right
        }

        public static let zero = SideInsets()
    }

    /// Works out the layout.
    ///
    /// - Parameters:
    ///   - size: The reader's size, edge to edge.
    ///   - fold: The frame of the active division region, if any, in the
    ///     reader's coordinates.
    ///   - insets: Side space to keep clear, such as the system rail.
    ///   - spread: The user's one-or-two-pages preference.
    ///   - flow: Pages or scroll.
    public static func resolve(
        size: CGSize,
        fold: CGRect?,
        insets: SideInsets = .zero,
        spread: ReaderSpread,
        flow: ReaderFlow
    ) -> ReaderLayout {
        let bounds = CGRect(origin: .zero, size: size)
        let left = max(0, insets.left)
        let right = max(0, insets.right)
        let usable = CGRect(x: left, y: 0, width: max(0, size.width - left - right), height: size.height)

        // A fold counts only when it lies fully inside the reader with room
        // for a page on each side; a sliver at the edge (say, when settings
        // narrow the reader) is treated as flat.
        guard let raw = fold, case let fold = raw.intersection(bounds), !fold.isNull,
              fold.width > 0 || fold.height > 0, hasRoomAround(raw, in: usable) else {
            let columns = columns(for: usable.size, spread: spread, flow: flow)
            // A spread is centred on the reader's middle, not the usable
            // area's: on an open Duo the middle is the hinge, and the rail on
            // one side would otherwise push the gap off it.
            let page = columns == 2 ? centred(on: size.width / 2, within: usable) : usable
            return ReaderLayout(pose: .flat, pageFrame: page, controlsFrame: nil, columns: columns, foldWidth: 0)
        }

        if fold.height >= fold.width {
            // Book: the fold runs top to bottom.
            if flow == .paged, spread != .single {
                // Readium splits a spread down its middle, so centre the page
                // view on the fold, even when the fold is off centre.
                let page = centred(on: fold.midX, within: usable)
                return ReaderLayout(pose: .book, pageFrame: page, controlsFrame: nil, columns: 2, foldWidth: fold.width)
            }
            // One page (scrolling, or the reader asked for one): it goes on
            // the left half and the controls on the right. Left, not leading,
            // because the halves are physical screen panels.
            let leftPanel = CGRect(x: usable.minX, y: 0, width: max(0, fold.minX - usable.minX), height: size.height)
            let rightPanel = CGRect(x: fold.maxX, y: 0, width: max(0, usable.maxX - fold.maxX), height: size.height)
            return ReaderLayout(pose: .book, pageFrame: leftPanel, controlsFrame: rightPanel, columns: 1, foldWidth: 0)
        }

        // Tabletop: the fold runs side to side.
        let top = CGRect(x: usable.minX, y: 0, width: usable.width, height: fold.minY)
        let bottom = CGRect(x: usable.minX, y: fold.maxY, width: usable.width, height: max(0, size.height - fold.maxY))
        return ReaderLayout(
            pose: .tabletop,
            pageFrame: top,
            controlsFrame: bottom,
            columns: columns(for: top.size, spread: spread, flow: flow),
            foldWidth: 0
        )
    }

    /// The widest frame inside `usable` whose middle is at `x`.
    static func centred(on x: CGFloat, within usable: CGRect) -> CGRect {
        let half = max(0, min(x - usable.minX, usable.maxX - x))
        return CGRect(x: x - half, y: usable.minY, width: 2 * half, height: usable.height)
    }

    /// Smallest side either side of the fold that's worth putting a page in.
    public static let minimumPanelLength: CGFloat = 200

    static func hasRoomAround(_ fold: CGRect, in usable: CGRect) -> Bool {
        if fold.height >= fold.width {
            return min(fold.minX - usable.minX, usable.maxX - fold.maxX) >= minimumPanelLength
        }
        return min(fold.minY - usable.minY, usable.maxY - fold.maxY) >= minimumPanelLength
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
