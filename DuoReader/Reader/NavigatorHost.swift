@preconcurrency import ReadiumNavigator
import SwiftUI
import UIKit

/// Embeds the Readium navigator in SwiftUI and routes taps and swipes on the page.
struct NavigatorHost: UIViewControllerRepresentable {
    let model: ReaderModel
    /// Passed in so SwiftUI updates the host when the settings change.
    let settings: ReaderSettings

    func makeUIViewController(context: Context) -> ReaderPageViewController {
        ReaderPageViewController(model: model)
    }

    func updateUIViewController(_ controller: ReaderPageViewController, context: Context) {
        controller.settingsDidChange()
    }
}

/// Hosts the navigator as a child view controller and turns its pages.
///
/// Taps are split into zones like Kindle: by default the outer quarter on each
/// side turns the page that way and the middle shows or hides the bars.
///
/// Page turns follow the chosen style. Slide is Readium's own paging, which
/// tracks the finger. Curl, fade and none are drawn here: the current page is
/// snapshotted, the navigator jumps to the next page without animation, and
/// the snapshot is animated away. For those styles the navigator's own swipe
/// paging is switched off and swipes are recognised here instead.
final class ReaderPageViewController: UIViewController {
    private let model: ReaderModel
    private var tapObserver: InputObservableToken?
    private var isTurning = false
    private lazy var swipeLeft = makeSwipe(.left)
    private lazy var swipeRight = makeSwipe(.right)

    /// Share of the width on each side that turns pages.
    static let edgeZoneFraction: CGFloat = 0.25
    static let turnDuration: TimeInterval = 0.4

    init(model: ReaderModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        guard let navigator = model.navigator else { return }

        addChild(navigator)
        navigator.view.frame = view.bounds
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigator.view)
        navigator.didMove(toParent: self)

        view.addGestureRecognizer(swipeLeft)
        view.addGestureRecognizer(swipeRight)

        // Weak captures: the navigator keeps its observers, so capturing it
        // strongly here would keep the whole navigator alive after closing.
        tapObserver = navigator.addObserver(.activate { [weak self, weak navigator] event in
            guard let self, let navigator else { return false }
            // VoiceOver users turn pages with VoiceOver's own gestures. A
            // double-tap on a paragraph near the edge must not turn the page.
            guard !UIAccessibility.isVoiceOverRunning else { return false }
            let zone = TapZone(point: event.location, in: navigator.view.bounds, edgeFraction: Self.edgeZoneFraction)
            switch TapAction(zone: zone, mode: self.model.settings.tapZones) {
            case .turn(let turn):
                await self.turn(turn)
            case .toggleControls:
                self.model.isChromeVisible.toggle()
            }
            return true
        })

        model.onLocationChange = { [weak self] in self?.updateNativePaging() }
        settingsDidChange()
    }

    /// Re-applies anything that depends on the settings.
    func settingsDidChange() {
        updateNativePaging()
    }

    // MARK: - Turning

    /// Turns the page with the current animation style.
    func turn(_ turn: PageTurn) async {
        guard !isTurning, let navigator = model.navigator else { return }
        let style = model.settings.pageTurn.effective(reduceMotion: UIAccessibility.isReduceMotionEnabled)

        // Scrolling books and PDFs keep the navigator's own animation.
        guard model.settings.flow == .paged, model.isReflowable, style == .curl || style == .fade else {
            _ = await model.turn(turn, animated: style == .slide)
            return
        }

        isTurning = true
        defer { isTurning = false }

        guard let before = navigator.view.snapshotView(afterScreenUpdates: false) else {
            _ = await model.turn(turn, animated: false)
            return
        }
        before.frame = navigator.view.frame
        view.addSubview(before)

        guard await model.turn(turn, animated: false) else {
            before.removeFromSuperview()
            return
        }
        // Give the web view a frame to draw the new page under the snapshot.
        try? await Task.sleep(for: .milliseconds(40))

        let forward = turn.isForward(rightToLeft: model.isRightToLeft)
        switch style {
        case .curl:
            await curl(away: before, forward: forward)
        default:
            await fade(away: before)
        }
    }

    private func fade(away snapshot: UIView) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            UIView.animate(withDuration: Self.turnDuration * 0.75, delay: 0, options: [.curveEaseInOut]) {
                snapshot.alpha = 0
            } completion: { _ in
                snapshot.removeFromSuperview()
                done.resume()
            }
        }
    }

    /// Curls the old page off like a book page: from the right edge going
    /// forward, back in from the left going backward.
    private func curl(away snapshot: UIView, forward: Bool) async {
        guard let navigator = model.navigator,
              let after = navigator.view.snapshotView(afterScreenUpdates: true) else {
            snapshot.removeFromSuperview()
            return
        }
        let pages = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        pages.isDoubleSided = false
        pages.view.frame = navigator.view.frame
        pages.view.isUserInteractionEnabled = false
        pages.setViewControllers([SnapshotPage(snapshot)], direction: .forward, animated: false)
        addChild(pages)
        view.addSubview(pages.view)
        pages.didMove(toParent: self)

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            pages.setViewControllers([SnapshotPage(after)], direction: forward ? .forward : .reverse, animated: true) { _ in
                done.resume()
            }
        }

        pages.willMove(toParent: nil)
        pages.view.removeFromSuperview()
        pages.removeFromParent()
    }

    // MARK: - Swipes

    private func makeSwipe(_ direction: UISwipeGestureRecognizer.Direction) -> UISwipeGestureRecognizer {
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(didSwipe(_:)))
        swipe.direction = direction
        swipe.isEnabled = false
        return swipe
    }

    @objc private func didSwipe(_ swipe: UISwipeGestureRecognizer) {
        // Swiping left reveals the page on the right.
        let turn: PageTurn = swipe.direction == .left ? .right : .left
        Task { await self.turn(turn) }
    }

    /// Readium pages by scrolling its web views. For curl, fade and none that
    /// paging is switched off so the page doesn't slide under the animation,
    /// and our own swipe recognisers take over.
    private func updateNativePaging() {
        guard let navigator = model.navigator, isViewLoaded else { return }
        let style = model.settings.pageTurn.effective(reduceMotion: UIAccessibility.isReduceMotionEnabled)
        let ownsSwipes = model.isReflowable && model.settings.flow == .paged && style != .slide
        swipeLeft.isEnabled = ownsSwipes
        swipeRight.isEnabled = ownsSwipes
        NativePaging.setEnabled(!ownsSwipes, in: navigator.view)
    }
}

/// Switches the swipe-to-page scrolling inside a Readium navigator on or off.
///
/// Readium doesn't expose this, so it walks the view tree for horizontally
/// paging scroll views (the spread pager and each page's web view). It runs
/// again after each page change, because Readium creates web views as it goes.
@MainActor
enum NativePaging {
    static func setEnabled(_ enabled: Bool, in root: UIView) {
        for scrollView in pagingScrollViews(in: root) {
            scrollView.panGestureRecognizer.isEnabled = enabled
        }
    }

    static func pagingScrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        if let scrollView = view as? UIScrollView, scrollView.isPagingEnabled {
            found.append(scrollView)
        }
        for subview in view.subviews {
            found += pagingScrollViews(in: subview)
        }
        return found
    }
}

/// A page in the curl animation, showing a snapshot.
private final class SnapshotPage: UIViewController {
    private let snapshot: UIView

    init(_ snapshot: UIView) {
        self.snapshot = snapshot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = UIView()
        snapshot.frame = view.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(snapshot)
    }
}
