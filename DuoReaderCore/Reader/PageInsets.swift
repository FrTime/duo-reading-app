import CoreGraphics

/// The space a reflowable page keeps clear at its top and bottom.
///
/// The top always clears the reader's title bar, whether or not the bar is
/// showing, so the first line is never hidden behind it and showing or
/// hiding the bars never reflows the book. The bottom is left to the
/// scrubber bar to cover while the controls show (as in Kindle): keeping
/// it clear would cost several lines on every page.
public struct PageInsets: Equatable, Sendable {
    public var top: CGFloat
    public var bottom: CGFloat

    /// Readium's own minimum margins, which we keep.
    public static let minimumCompact: CGFloat = 34
    public static let minimumRegular: CGFloat = 62
    /// Gap between the bar's bottom edge and the first line.
    public static let barGap: CGFloat = 8

    public init(top: CGFloat, bottom: CGFloat) {
        self.top = top
        self.bottom = bottom
    }

    /// - Parameters:
    ///   - windowTop: The window's top safe-area inset (status bar, notch).
    ///   - windowBottom: The window's bottom safe-area inset.
    ///   - barBottom: Where the reader's title bar ends, measured from the
    ///     top of the window while it shows; 0 if not measured yet.
    ///   - compactHeight: Whether the vertical size class is compact.
    public static func resolve(
        windowTop: CGFloat,
        windowBottom: CGFloat,
        barBottom: CGFloat,
        compactHeight: Bool
    ) -> PageInsets {
        let minimum = compactHeight ? minimumCompact : minimumRegular
        let clearOfBar = barBottom > 0 ? barBottom + barGap : 0
        return PageInsets(
            top: max(windowTop, minimum, clearOfBar).rounded(.up),
            bottom: max(windowBottom, minimum).rounded(.up)
        )
    }
}

/// Space kept clear around fixed-layout pages, with equal left and right.
public struct FixedLayoutInsets: Equatable, Sendable {
    public var top: CGFloat
    /// Both the left and the right.
    public var side: CGFloat
    public var bottom: CGFloat

    public init(top: CGFloat, side: CGFloat, bottom: CGFloat) {
        self.top = top
        self.side = side
        self.bottom = bottom
    }

    public static let zero = FixedLayoutInsets(top: 0, side: 0, bottom: 0)
}
