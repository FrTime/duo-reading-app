import CoreGraphics

/// Which part of the page a tap landed in.
public enum TapZone: Equatable, Sendable {
    case left
    case center
    case right

    public init(point: CGPoint, in bounds: CGRect, edgeFraction: CGFloat) {
        guard bounds.width > 0 else {
            self = .center
            return
        }
        let x = (point.x - bounds.minX) / bounds.width
        if x < edgeFraction {
            self = .left
        } else if x > 1 - edgeFraction {
            self = .right
        } else {
            self = .center
        }
    }
}

/// A page turn, either toward a screen side or along the reading order.
public enum PageTurn: Equatable, Sendable {
    case left
    case right
    case forward
    case backward

    /// Whether the turn moves on through the book. Left and right depend on
    /// the reading direction: in a right-to-left book, left is forward.
    public func isForward(rightToLeft: Bool) -> Bool {
        switch self {
        case .forward: true
        case .backward: false
        case .right: !rightToLeft
        case .left: rightToLeft
        }
    }
}

/// What a tap does.
public enum TapAction: Equatable, Sendable {
    case turn(PageTurn)
    case toggleControls

    public init(zone: TapZone, mode: TapZoneMode) {
        switch (zone, mode) {
        case (.center, _), (_, .off):
            self = .toggleControls
        case (.left, .backAndForward):
            self = .turn(.left)
        case (.right, .backAndForward):
            self = .turn(.right)
        case (.left, .forwardOnly), (.right, .forwardOnly):
            self = .turn(.forward)
        }
    }
}

extension PageTurnStyle {
    /// The style to use, given Reduce Motion. Curl and slide move the whole
    /// page across the screen, so Reduce Motion swaps them for a fade.
    public func effective(reduceMotion: Bool) -> PageTurnStyle {
        guard reduceMotion else { return self }
        switch self {
        case .slide, .curl: return .fade
        case .fade, .none: return self
        }
    }
}

extension PageTurn {
    /// Whether the turn reveals the page on the right, which decides which
    /// edge a curl starts from.
    public func revealsRight(rightToLeft: Bool) -> Bool {
        isForward(rightToLeft: rightToLeft) != rightToLeft
    }
}

/// How a page turn is drawn, and whether the reader's own swipe recognisers
/// replace Readium's swipe paging.
public struct TurnPlan: Equatable, Sendable {
    public enum Animation: Equatable, Sendable {
        /// Readium turns the page itself, sliding or instantly.
        case native(animated: Bool)
        /// The reader snapshots the page and curls it away.
        case curl
        /// The reader snapshots the page and fades it out.
        case fade
    }

    public var animation: Animation
    /// True when Readium's swipe paging is off and the reader's swipes turn
    /// pages, so every turn uses the chosen style.
    public var ownsSwipes: Bool

    public init(style: PageTurnStyle, flow: ReaderFlow, isReflowable: Bool, reduceMotion: Bool) {
        let style = style.effective(reduceMotion: reduceMotion)
        // Curl and fade need whole pages: reflowable books in paged flow.
        // Scrolling books and PDFs use Readium's own animation.
        let drawsTurns = flow == .paged && isReflowable
        ownsSwipes = drawsTurns && style != .slide
        switch style {
        case .curl where drawsTurns:
            animation = .curl
        case .fade where drawsTurns:
            animation = .fade
        case .none:
            animation = .native(animated: false)
        default:
            animation = .native(animated: true)
        }
    }
}
