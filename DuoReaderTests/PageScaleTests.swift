import CoreGraphics
import Foundation
import Testing
@testable import DuoReader

struct PageScaleTests {
    // A portrait manga page, 1000 × 1500 px, on the closed Duo's tall screen:
    // a 400 × 860 pt web view with 50 pt kept clear at the top and 30 at the
    // bottom. Readium fits the page to the 400 pt width.
    let view = CGSize(width: 400, height: 860)
    let viewport = CGRect(x: 0, y: 50, width: 400, height: 780)
    let fitZoom: CGFloat = 0.4
    /// The page in document coordinates (the document is view / fitZoom =
    /// 1000 × 2150), centred.
    let page = CGRect(x: 0, y: 325, width: 1000, height: 1500)

    func plan(_ scale: PageScale, rightToLeft: Bool = false, maximumZoom: CGFloat = 5) -> PageScalePlan {
        PageScalePlan.resolve(
            scale, content: page, viewport: viewport, viewSize: view,
            fitZoom: fitZoom, maximumZoom: maximumZoom, screenScale: 3, rightToLeft: rightToLeft
        )
    }

    @Test func fitPageAndStretchLeaveTheEngineAlone() {
        #expect(plan(.fitPage) == PageScalePlan(zoom: fitZoom, offset: .zero))
        #expect(plan(.stretch) == PageScalePlan(zoom: fitZoom, offset: .zero))
    }

    @Test func fitWidthOnAPageAlreadyFittedByWidthChangesNothingVisible() {
        // The page is 400 pt wide at the fit zoom, the viewport's width.
        let p = plan(.fitWidth)
        #expect(abs(p.zoom - fitZoom) < 0.0001)
    }

    @Test func fitHeightMakesThePageAsTallAsTheViewport() throws {
        let p = plan(.fitHeight)
        #expect(abs(page.height * p.zoom - viewport.height) < 0.01)
        // Wider than the screen now: starts at the left edge, top aligned.
        #expect(abs(p.offset.x - page.minX * p.zoom) < 0.01)
        #expect(abs(p.offset.y - (page.minY * p.zoom - viewport.minY)) < 0.01)
    }

    @Test func rightToLeftBooksStartAtTheRightEdge() {
        let p = plan(.fitHeight, rightToLeft: true)
        #expect(abs(p.offset.x - (page.maxX * p.zoom - viewport.maxX)) < 0.01)
    }

    @Test func fillCoversTheViewportAndCentres() {
        let p = plan(.fill)
        let shown = CGRect(x: page.minX * p.zoom, y: page.minY * p.zoom, width: page.width * p.zoom, height: page.height * p.zoom)
        #expect(shown.width >= viewport.width - 0.01)
        #expect(shown.height >= viewport.height - 0.01)
        #expect(abs((shown.midX - p.offset.x) - viewport.midX) < 0.01)
        #expect(abs((shown.midY - p.offset.y) - viewport.midY) < 0.01)
    }

    @Test func originalShowsOneScanPixelPerScreenPixel() {
        let p = PageScalePlan.resolve(
            .original, content: page, viewport: viewport, viewSize: view,
            fitZoom: fitZoom, maximumZoom: 5, screenScale: 2, rightToLeft: false
        )
        #expect(abs(p.zoom - 0.5) < 0.0001)
    }

    @Test func neverZoomsOutPastTheFitOrInPastTheMaximum() {
        // A tiny scan: 1:1 pixels would be smaller than the fit.
        let small = PageScalePlan.resolve(
            .original, content: page, viewport: viewport, viewSize: view,
            fitZoom: 0.5, maximumZoom: 5, screenScale: 3, rightToLeft: false
        )
        #expect(small.zoom == 0.5)
        #expect(plan(.fitHeight, maximumZoom: 0.45).zoom == 0.45)
    }

    @Test func offsetsStayInsideTheScrollableArea() {
        for scale in PageScale.allCases {
            for rtl in [false, true] {
                let p = plan(scale, rightToLeft: rtl)
                let factor = p.zoom / fitZoom
                #expect(p.offset.x >= 0 && p.offset.x <= view.width * factor - view.width + 0.01)
                #expect(p.offset.y >= 0 && p.offset.y <= view.height * factor - view.height + 0.01)
            }
        }
    }

    @Test func emptyMeasurementsFallBackToTheFit() {
        let p = PageScalePlan.resolve(
            .fill, content: .zero, viewport: viewport, viewSize: view,
            fitZoom: fitZoom, maximumZoom: 5, screenScale: 3, rightToLeft: false
        )
        #expect(p == PageScalePlan(zoom: fitZoom, offset: .zero))
    }

    @Test func onlyZoomingModesZoom() {
        #expect(!PageScale.fitPage.zooms)
        #expect(!PageScale.stretch.zooms)
        #expect(PageScale.fill.zooms)
    }

    // MARK: - Settings and storage

    @Test func defaultIsFitPageAndDecodesFromOldSettings() throws {
        #expect(ReaderSettings.default.pageScale == .fitPage)
        let old = try JSONDecoder().decode(ReaderSettings.self, from: Data(#"{"theme":"sepia"}"#.utf8))
        #expect(old.pageScale == .fitPage)
        let unknown = try JSONDecoder().decode(ReaderSettings.self, from: Data(#"{"pageScale":"zoomToPanel"}"#.utf8))
        #expect(unknown.pageScale == .fitPage)
    }

    @Test func settingsRoundTripThePageScale() throws {
        var s = ReaderSettings()
        s.pageScale = .fill
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(ReaderSettings.self, from: data).pageScale == .fill)
    }

    @Test func storeRemembersEachBookSeparately() {
        let suite = "PageScaleTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = PageScaleStore(suiteName: suite)
        let a = UUID(), b = UUID()
        #expect(store.scale(for: a) == nil)
        store.setScale(.fill, for: a)
        store.setScale(.stretch, for: b)
        #expect(store.scale(for: a) == .fill)
        #expect(store.scale(for: b) == .stretch)
        store.setScale(nil, for: a)
        #expect(store.scale(for: a) == nil)
        #expect(store.scale(for: b) == .stretch)
    }
}
