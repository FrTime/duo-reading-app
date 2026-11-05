import CoreGraphics
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

    @Test func curlsStartFromTheSideBeingRevealed() {
        #expect(PageTurn.right.revealsRight(rightToLeft: false))
        #expect(PageTurn.right.revealsRight(rightToLeft: true))
        #expect(!PageTurn.left.revealsRight(rightToLeft: true))
        #expect(PageTurn.forward.revealsRight(rightToLeft: false))
        // In a right-to-left book the next page is on the left.
        #expect(!PageTurn.forward.revealsRight(rightToLeft: true))
        #expect(PageTurn.backward.revealsRight(rightToLeft: true))
    }

    @Test(arguments: [
        (CGFloat(99), TapZone.left), (100, .center), (300, .center), (301, .right), (500, .right),
    ])
    func tapZonesSplitAtTheQuarters(x: CGFloat, zone: TapZone) {
        let bounds = CGRect(x: 100, y: 0, width: 400, height: 800)
        #expect(TapZone(point: CGPoint(x: x + 100, y: 10), in: bounds, edgeFraction: 0.25) == zone)
    }

    @Test func zeroWidthTapsShowControls() {
        #expect(TapZone(point: .zero, in: .zero, edgeFraction: 0.25) == .center)
    }
}

struct TurnPlanTests {
    @Test func pagedBooksDrawCurlAndFadeAndOwnSwipes() {
        let curl = TurnPlan(style: .curl, flow: .paged, isReflowable: true, reduceMotion: false)
        #expect(curl.animation == .curl)
        #expect(curl.ownsSwipes)
        let fade = TurnPlan(style: .fade, flow: .paged, isReflowable: true, reduceMotion: false)
        #expect(fade.animation == .fade)
        #expect(fade.ownsSwipes)
    }

    @Test func slideIsReadiumsOwn() {
        let plan = TurnPlan(style: .slide, flow: .paged, isReflowable: true, reduceMotion: false)
        #expect(plan.animation == .native(animated: true))
        #expect(!plan.ownsSwipes)
    }

    @Test func noAnimationStillOwnsSwipesSoTheyDoNotSlide() {
        let plan = TurnPlan(style: .none, flow: .paged, isReflowable: true, reduceMotion: false)
        #expect(plan.animation == .native(animated: false))
        #expect(plan.ownsSwipes)
    }

    @Test func pdfsAndScrollingUseReadiumsAnimation() {
        for (flow, reflowable) in [(ReaderFlow.paged, false), (.scroll, true)] {
            let plan = TurnPlan(style: .curl, flow: flow, isReflowable: reflowable, reduceMotion: false)
            #expect(plan.animation == .native(animated: true))
            #expect(!plan.ownsSwipes)
        }
    }

    @Test func reduceMotionFadesInsteadOfSliding() {
        let plan = TurnPlan(style: .slide, flow: .paged, isReflowable: true, reduceMotion: true)
        #expect(plan.animation == .fade)
        #expect(plan.ownsSwipes)
    }
}
