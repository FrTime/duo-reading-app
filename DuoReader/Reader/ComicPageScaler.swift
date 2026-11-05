import UIKit
import WebKit

/// Sizes the pages of a fixed-layout book (comics) to the chosen `PageScale`.
///
/// Readium fits each page, or two-page spread, to the screen, and its web
/// views can be pinch-zoomed. Readium doesn't offer the other modes, so this
/// finds its web views and zooms them as a pinch would, which keeps the page
/// pannable where it's bigger than the screen. Stretch can't be a zoom, so it
/// reshapes the pages with a style sheet in Readium's wrapper page instead.
///
/// Each web view is zoomed once per page and layout, so a pinch or pan by
/// the reader isn't undone until the page, the size or the mode changes.
@MainActor
final class ComicPageScaler {
    /// What each web view was last scaled for.
    private let applied = NSMapTable<WKWebView, AppliedScale>.weakToStrongObjects()
    private var retry: Task<Void, Never>?
    private var hasScaled = false

    /// Delays before checking again. Readium lays pages out asynchronously,
    /// in its web views, after a page loads or the view changes size, and
    /// re-fitting a page undoes the zoom; nothing reports when it's done, so
    /// look again a few times. Pages that haven't changed are skipped.
    private static let followUpDelays: [Duration] = [.milliseconds(150), .milliseconds(400), .milliseconds(1000)]

    /// Scales every page web view under `root`.
    ///
    /// - Parameters:
    ///   - insets: The space Readium keeps clear around pages (see
    ///     `ReaderModel.fixedPageInsets`), which the modes fill up to.
    ///   - force: Re-apply even where nothing seems to have changed, e.g.
    ///     after the reader picked a new mode.
    func apply(_ scale: PageScale, in root: UIView, insets: FixedLayoutInsets, rightToLeft: Bool, force: Bool = false) {
        // Nothing to undo until a page has been zoomed or stretched.
        if scale == .fitPage, !hasScaled { return }
        hasScaled = true
        retry?.cancel()
        if force { applied.removeAllObjects() }
        retry = Task { [weak self, weak root] in
            if let root {
                await self?.scale(Self.webViews(in: root), to: scale, insets: insets, rightToLeft: rightToLeft)
            }
            for delay in Self.followUpDelays {
                try? await Task.sleep(for: delay)
                // Readium adds and removes web views as pages change.
                guard !Task.isCancelled, let root else { return }
                await self?.scale(Self.webViews(in: root), to: scale, insets: insets, rightToLeft: rightToLeft)
            }
        }
    }

    /// Forgets what was applied, e.g. when the book closes.
    func cancel() {
        retry?.cancel()
        retry = nil
    }

    private func scale(_ webViews: [WKWebView], to scale: PageScale, insets: FixedLayoutInsets, rightToLeft: Bool) async {
        for webView in webViews where webView.window != nil {
            guard !Task.isCancelled else { return }
            await self.scale(webView, to: scale, insets: insets, rightToLeft: rightToLeft)
        }
    }

    /// Zooms one web view. A page that hasn't loaded yet is left for a
    /// later pass.
    private func scale(_ webView: WKWebView, to scale: PageScale, insets: FixedLayoutInsets, rightToLeft: Bool) async {
        let scrollView = webView.scrollView
        let fitZoom = scrollView.minimumZoomScale
        let size = webView.bounds.size
        guard fitZoom > 0, size.width > 0, size.height > 0 else { return }
        let viewport = Self.viewport(of: webView, insets: insets)

        // The document spans the web view at the fit zoom, so the viewport in
        // document coordinates is the viewport divided by it.
        let target = CGRect(
            x: viewport.minX / fitZoom, y: viewport.minY / fitZoom,
            width: viewport.width / fitZoom, height: viewport.height / fitZoom
        )
        let script = Self.measureScript(stretch: scale == .stretch, target: target)
        guard let result = try? await webView.evaluateJavaScript(script) as? [Double], result.count == 4 else {
            return
        }
        let content = CGRect(x: result[0], y: result[1], width: result[2], height: result[3])
        guard content.width > 0, content.height > 0 else { return }

        let plan = PageScalePlan.resolve(
            scale,
            content: content,
            viewport: viewport,
            viewSize: size,
            fitZoom: fitZoom,
            maximumZoom: scrollView.maximumZoomScale,
            screenScale: webView.window?.screen.scale ?? webView.traitCollection.displayScale,
            rightToLeft: rightToLeft
        )
        let key = AppliedScale(scale: scale, size: size, fitZoom: fitZoom, content: content.integral)
        if applied.object(forKey: webView) == key {
            // Already done; leave any pinch or pan alone. But if WebKit has
            // dropped back to the fit zoom on its own, as it can when Readium
            // rewrites the page's viewport, zoom again.
            let wasReset = abs(scrollView.zoomScale - fitZoom) < 0.001 && plan.zoom > fitZoom + 0.001
            guard wasReset, !scrollView.isTracking, !scrollView.isZooming else { return }
        }
        applied.setObject(key, forKey: webView)

        scrollView.setZoomScale(plan.zoom, animated: false)
        scrollView.setContentOffset(plan.offset, animated: false)
    }

    /// The part of the web view to fill: the space Readium fits pages into.
    /// (Each page's web view spans the navigator, wherever it has scrolled to.)
    static func viewport(of webView: WKWebView, insets: FixedLayoutInsets) -> CGRect {
        let bounds = webView.bounds
        let inner = bounds.inset(by: UIEdgeInsets(top: insets.top, left: insets.side, bottom: insets.bottom, right: insets.side))
        return inner.width > 0 && inner.height > 0 ? inner : bounds
    }

    /// Readium's page web views: every web view in the navigator. For a
    /// fixed-layout book they all show pages.
    static func webViews(in view: UIView) -> [WKWebView] {
        if let webView = view as? WKWebView { return [webView] }
        return view.subviews.flatMap(webViews(in:))
    }

    /// Script for Readium's wrapper page (the main frame), which holds each
    /// page in an iframe. It returns the box around the pages showing, in
    /// document coordinates, as `[x, y, width, height]`, or an empty array if
    /// none has loaded.
    ///
    /// With `stretch`, it then reshapes each page to fill `target` (a half
    /// each in a two-page spread) with an !important style sheet, which wins
    /// over the inline styles Readium sets as it lays pages out. Otherwise it
    /// removes that sheet.
    static func measureScript(stretch: Bool, target: CGRect) -> String {
        """
        (function () {
          var stretch = \(stretch), t = { x: \(target.minX), y: \(target.minY), w: \(target.width), h: \(target.height) };
          var old = document.getElementById('duo-page-scale');
          if (old) { old.remove(); }
          var sx = window.scrollX, sy = window.scrollY;
          var frames = Array.prototype.filter.call(document.querySelectorAll('iframe'), function (f) {
            return parseFloat(f.style.width) > 0 && parseFloat(f.style.height) > 0 && f.offsetParent !== null;
          });
          if (frames.length === 0) { return []; }
          var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
          frames.forEach(function (f) {
            var r = f.getBoundingClientRect();
            minX = Math.min(minX, r.left + sx); minY = Math.min(minY, r.top + sy);
            maxX = Math.max(maxX, r.right + sx); maxY = Math.max(maxY, r.bottom + sy);
          });
          if (stretch) {
            var css = '';
            frames.forEach(function (f) {
              if (!f.id) { return; }
              var box = { x: t.x, y: t.y, w: t.w, h: t.h };
              if (f.id === 'page-left') { box.w = t.w / 2; }
              if (f.id === 'page-right') { box.x = t.x + t.w / 2; box.w = t.w / 2; }
              var parent = f.offsetParent.getBoundingClientRect();
              var w = parseFloat(f.style.width), h = parseFloat(f.style.height);
              css += '#' + f.id + ' { left: ' + (box.x - parent.left - sx) + 'px !important; top: ' + (box.y - parent.top - sy) +
                'px !important; right: auto !important; bottom: auto !important; transform-origin: 0 0 !important; ' +
                'transform: scale(' + (box.w / w) + ', ' + (box.h / h) + ') !important; }\\n';
            });
            var style = document.createElement('style');
            style.id = 'duo-page-scale';
            style.textContent = css;
            document.head.appendChild(style);
          }
          return [minX, minY, maxX - minX, maxY - minY];
        })();
        """
    }
}

/// What a web view was scaled for, to skip work when nothing changed.
private final class AppliedScale: NSObject {
    let scale: PageScale
    let size: CGSize
    let fitZoom: CGFloat
    let content: CGRect

    init(scale: PageScale, size: CGSize, fitZoom: CGFloat, content: CGRect) {
        self.scale = scale
        self.size = size
        self.fitZoom = fitZoom
        self.content = content
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? AppliedScale else { return false }
        return scale == other.scale && size == other.size && fitZoom == other.fitZoom && content == other.content
    }

    override var hash: Int { scale.hashValue }
}
