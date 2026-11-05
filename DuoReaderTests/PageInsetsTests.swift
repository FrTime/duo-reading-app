import CoreGraphics
import Testing
@testable import DuoReader

struct PageInsetsTests {
    @Test func topClearsTheTitleBar() {
        // Open Duo: the bar ends at 81 pt, below Readium's 62 pt margin.
        let insets = PageInsets.resolve(windowTop: 24, windowBottom: 20, barBottom: 81, compactHeight: false)
        #expect(insets.top == 81 + PageInsets.barGap)
    }

    @Test func bottomKeepsReadiumsMarginNotTheScrubber() {
        let insets = PageInsets.resolve(windowTop: 24, windowBottom: 20, barBottom: 81, compactHeight: false)
        #expect(insets.bottom == PageInsets.minimumRegular)
    }

    @Test func unmeasuredBarFallsBackToReadiumsMargins() {
        let regular = PageInsets.resolve(windowTop: 0, windowBottom: 0, barBottom: 0, compactHeight: false)
        #expect(regular == PageInsets(top: 62, bottom: 62))
        let compact = PageInsets.resolve(windowTop: 0, windowBottom: 0, barBottom: 0, compactHeight: true)
        #expect(compact == PageInsets(top: 34, bottom: 34))
    }

    @Test func windowInsetsWinWhenLarger() {
        let insets = PageInsets.resolve(windowTop: 70, windowBottom: 90, barBottom: 0, compactHeight: false)
        #expect(insets == PageInsets(top: 70, bottom: 90))
    }

    @Test func fractionalPointsRoundUp() {
        let insets = PageInsets.resolve(windowTop: 0, windowBottom: 0, barBottom: 100.3, compactHeight: false)
        #expect(insets.top == 109)
    }
}
