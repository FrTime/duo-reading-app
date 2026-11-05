import CoreGraphics
import Foundation
import Testing
@testable import DuoReader

struct PageTurningTests {
    @Test(arguments: [
        (TapZone.left, TapZoneMode.backAndForward, TapAction.turn(.left)),
        (.right, .backAndForward, .turn(.right)),
        (.center, .backAndForward, .toggleControls),
        (.left, .forwardOnly, .turn(.forward)),
        (.right, .forwardOnly, .turn(.forward)),
        (.center, .forwardOnly, .toggleControls),
        (.left, .off, .toggleControls),
        (.right, .off, .toggleControls),
    ])
    func tapsMapToActions(zone: TapZone, mode: TapZoneMode, action: TapAction) {
        #expect(TapAction(zone: zone, mode: mode) == action)
    }

    @Test func sidesFollowTheReadingDirection() {
        #expect(PageTurn.right.isForward(rightToLeft: false))
        #expect(!PageTurn.left.isForward(rightToLeft: false))
        #expect(PageTurn.left.isForward(rightToLeft: true))
        #expect(!PageTurn.right.isForward(rightToLeft: true))
        #expect(PageTurn.forward.isForward(rightToLeft: true))
        #expect(!PageTurn.backward.isForward(rightToLeft: false))
    }

    @Test func reduceMotionSwapsMovingStylesForAFade() {
        #expect(PageTurnStyle.curl.effective(reduceMotion: true) == .fade)
        #expect(PageTurnStyle.slide.effective(reduceMotion: true) == .fade)
        #expect(PageTurnStyle.none.effective(reduceMotion: true) == PageTurnStyle.none)
        #expect(PageTurnStyle.curl.effective(reduceMotion: false) == .curl)
    }
}

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
