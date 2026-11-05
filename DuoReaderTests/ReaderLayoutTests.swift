import CoreGraphics
import Foundation
import Testing
@testable import DuoReader

struct ReaderLayoutTests {
    // Rough iPhone Duo sizes in points; exact values don't matter to the rules.
    let outer = CGSize(width: 400, height: 860)
    let innerTall = CGSize(width: 760, height: 860)
    let innerWide = CGSize(width: 860, height: 760)

    @Test func closedShowsOnePage() {
        let layout = ReaderLayout.resolve(size: outer, fold: nil, spread: .automatic, flow: .paged)
        #expect(layout.pose == .flat)
        #expect(layout.columns == 1)
        #expect(layout.pageFrame == CGRect(origin: .zero, size: outer))
        #expect(layout.controlsFrame == nil)
    }

    @Test func openWideShowsASpread() {
        let layout = ReaderLayout.resolve(size: innerWide, fold: nil, spread: .automatic, flow: .paged)
        #expect(layout.pose == .flat)
        #expect(layout.columns == 2)
    }

    @Test func openTallShowsOnePageUnlessAskedForTwo() {
        #expect(ReaderLayout.resolve(size: innerTall, fold: nil, spread: .automatic, flow: .paged).columns == 1)
        #expect(ReaderLayout.resolve(size: innerTall, fold: nil, spread: .double, flow: .paged).columns == 2)
    }

    @Test func twoPagesNeedRoom() {
        #expect(ReaderLayout.resolve(size: outer, fold: nil, spread: .double, flow: .paged).columns == 1)
    }

    @Test func singleAndScrollAlwaysShowOnePage() {
        #expect(ReaderLayout.resolve(size: innerWide, fold: nil, spread: .single, flow: .paged).columns == 1)
        #expect(ReaderLayout.resolve(size: innerWide, fold: nil, spread: .double, flow: .scroll).columns == 1)
    }

    @Test func bookPosePutsAPageOnEachSide() {
        let fold = CGRect(x: 370, y: 0, width: 20, height: 860)
        let layout = ReaderLayout.resolve(size: innerTall, fold: fold, spread: .automatic, flow: .paged)
        #expect(layout.pose == .book)
        #expect(layout.columns == 2)
        #expect(layout.foldWidth == 20)
        #expect(layout.pageFrame == CGRect(origin: .zero, size: innerTall))
    }

    @Test func bookPoseCentresTheSpreadOnAnOffCentreFold() {
        // Readium splits a spread down its middle, so the crease must be the middle.
        let fold = CGRect(x: 400, y: 0, width: 20, height: 860)
        let layout = ReaderLayout.resolve(size: innerTall, fold: fold, spread: .automatic, flow: .paged)
        #expect(layout.pageFrame.midX == fold.midX)
        #expect(layout.pageFrame.minX >= 0)
        #expect(layout.pageFrame.maxX <= innerTall.width)
    }

    @Test func bookPoseWithOnePageKeepsItOffTheFold() {
        let fold = CGRect(x: 370, y: 0, width: 20, height: 860)
        let layout = ReaderLayout.resolve(size: innerTall, fold: fold, spread: .automatic, flow: .scroll)
        #expect(layout.pose == .book)
        #expect(layout.columns == 1)
        #expect(layout.pageFrame == CGRect(x: 0, y: 0, width: 370, height: 860))
        #expect(layout.controlsFrame == CGRect(x: 390, y: 0, width: 370, height: 860))
        #expect(layout.foldWidth == 0)
    }

    @Test func tabletopPutsThePageAboveTheFoldAndControlsBelow() {
        let fold = CGRect(x: 0, y: 370, width: 860, height: 20)
        let layout = ReaderLayout.resolve(size: innerWide, fold: fold, spread: .automatic, flow: .paged)
        #expect(layout.pose == .tabletop)
        #expect(layout.pageFrame == CGRect(x: 0, y: 0, width: 860, height: 370))
        #expect(layout.controlsFrame == CGRect(x: 0, y: 390, width: 860, height: 370))
        // The upper half is wide and short, so it gets a spread.
        #expect(layout.columns == 2)
    }

    @Test func aFoldOutsideTheReaderIsIgnored() {
        let fold = CGRect(x: 2000, y: 0, width: 20, height: 860)
        #expect(ReaderLayout.resolve(size: innerTall, fold: fold, spread: .automatic, flow: .paged).pose == .flat)
    }

    @Test func extraMarginClearsTheFold() {
        let fold = CGRect(x: 370, y: 0, width: 20, height: 860)
        let layout = ReaderLayout.resolve(size: innerTall, fold: fold, spread: .automatic, flow: .paged)
        // Gap = 2 × gutter × extra = fold width.
        let extra = layout.extraMarginFactor(gutter: 20)
        #expect(abs(2 * 20 * extra - 20) < 0.0001)
        #expect(ReaderLayout.resolve(size: innerTall, fold: nil, spread: .automatic, flow: .paged).extraMarginFactor(gutter: 20) == 0)
    }
}
