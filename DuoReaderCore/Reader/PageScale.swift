import CoreGraphics
import Foundation

/// How a comic or other fixed-layout page is sized on the screen.
///
/// The reader engine always lays a page (or a two-page spread) out to fit
/// the screen. Every other mode starts from that and zooms the page's web
/// view, the same as pinching it, so a page bigger than the screen can be
/// panned. Stretch can't be a zoom, as it scales width and height by
/// different amounts, so it reshapes the page itself.
public enum PageScale: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The whole page on screen, with bands at the sides or ends.
    case fitPage
    /// Page width matches the screen; scroll down for the rest.
    case fitWidth
    /// Page height matches the screen; pan sideways for the rest.
    case fitHeight
    /// Fills the screen with no bands, cropping what doesn't fit (pan to see it).
    case fill
    /// Fills the screen exactly, changing the page's shape.
    case stretch
    /// One pixel of the scan for each pixel of the screen.
    case original

    public var id: Self { self }

    /// Whether the page is zoomed rather than reshaped.
    public var zooms: Bool {
        self != .fitPage && self != .stretch
    }
}

/// Where to zoom and scroll a page's web view for a `PageScale`.
///
/// Coordinates follow WebKit's scroll view: a point `p` in the page's
/// document shows at `p × zoom − offset` in the web view.
public struct PageScalePlan: Equatable, Sendable {
    public var zoom: CGFloat
    public var offset: CGPoint

    public init(zoom: CGFloat, offset: CGPoint) {
        self.zoom = zoom
        self.offset = offset
    }

    /// - Parameters:
    ///   - scale: The mode.
    ///   - content: The page or spread, in document coordinates.
    ///   - viewport: The area to fill, in web view coordinates (the web view
    ///     minus the safe area).
    ///   - viewSize: The web view's size.
    ///   - fitZoom: The zoom at which the engine fits the page, which is also
    ///     the smallest zoom allowed. The document spans the web view there.
    ///   - maximumZoom: The largest zoom allowed.
    ///   - screenScale: Screen pixels per point, for `original`.
    ///   - rightToLeft: Whether the book reads right to left, so a page
    ///     wider than the screen starts at its right edge.
    public static func resolve(
        _ scale: PageScale,
        content: CGRect,
        viewport: CGRect,
        viewSize: CGSize,
        fitZoom: CGFloat,
        maximumZoom: CGFloat,
        screenScale: CGFloat,
        rightToLeft: Bool
    ) -> PageScalePlan {
        let none = PageScalePlan(zoom: fitZoom, offset: .zero)
        guard fitZoom > 0, content.width > 0, content.height > 0,
              viewport.width > 0, viewport.height > 0 else { return none }

        // The page as it shows at the fit zoom.
        let fitted = CGSize(width: content.width * fitZoom, height: content.height * fitZoom)
        let wanted: CGFloat
        switch scale {
        case .fitPage, .stretch:
            return none
        case .fitWidth:
            wanted = fitZoom * viewport.width / fitted.width
        case .fitHeight:
            wanted = fitZoom * viewport.height / fitted.height
        case .fill:
            wanted = fitZoom * max(viewport.width / fitted.width, viewport.height / fitted.height)
        case .original:
            wanted = screenScale > 0 ? 1 / screenScale : fitZoom
        }
        let zoom = min(max(wanted, fitZoom), max(maximumZoom, fitZoom))

        let shown = CGRect(
            x: content.minX * zoom, y: content.minY * zoom,
            width: content.width * zoom, height: content.height * zoom
        )
        // A rounding error's worth of overflow still counts as fitting.
        let tolerance: CGFloat = 1
        let overflowsX = shown.width > viewport.width + tolerance
        let overflowsY = shown.height > viewport.height + tolerance

        var x: CGFloat
        if overflowsX, scale != .fill {
            // Start where reading starts.
            x = rightToLeft ? shown.maxX - viewport.maxX : shown.minX - viewport.minX
        } else {
            x = shown.midX - viewport.midX
        }
        var y: CGFloat
        if overflowsY, scale != .fill {
            y = shown.minY - viewport.minY
        } else {
            y = shown.midY - viewport.midY
        }

        // The document spans the web view at the fit zoom, so it's that size
        // times the extra zoom.
        let factor = zoom / fitZoom
        let maxX = max(0, viewSize.width * factor - viewSize.width)
        let maxY = max(0, viewSize.height * factor - viewSize.height)
        x = min(max(x, 0), maxX)
        y = min(max(y, 0), maxY)
        return PageScalePlan(zoom: zoom, offset: CGPoint(x: x, y: y))
    }
}

// MARK: - Storage

/// Remembers the page scale chosen for each book, by the book's ID.
///
/// Kept in user defaults rather than on the library's `Book` model, so it
/// needs no store migration. A book with no entry uses the default in
/// `ReaderSettings.pageScale`.
public struct PageScaleStore: Sendable {
    public static let key = "reader.pageScaleByBook.v1"
    private let defaultsSuite: String?

    /// - Parameter suiteName: A user defaults suite, for tests. Nil uses the standard defaults.
    public init(suiteName: String? = nil) {
        defaultsSuite = suiteName
    }

    private var defaults: UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// The book's own scale, or nil if it follows the default.
    public func scale(for bookID: UUID) -> PageScale? {
        let saved = defaults.dictionary(forKey: Self.key) as? [String: String]
        return saved?[bookID.uuidString].flatMap(PageScale.init(rawValue:))
    }

    /// Sets the book's own scale; nil makes it follow the default again.
    public func setScale(_ scale: PageScale?, for bookID: UUID) {
        var saved = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        saved[bookID.uuidString] = scale?.rawValue
        defaults.set(saved, forKey: Self.key)
    }
}
