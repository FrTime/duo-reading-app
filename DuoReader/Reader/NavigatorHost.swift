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
    private var accessibilityObservers: [NSObjectProtocol] = []
    /// The last plan applied, so SwiftUI updates that don't change it skip
    /// the view-tree walk.
    private var appliedPlan: TurnPlan?
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
                // A tap during a turn animation is left unhandled, not lost.
                return await self.turn(turn)
            case .toggleControls:
                self.model.isChromeVisible.toggle()
                return true
            }
        })

        // Readium makes new web views as pages change and when settings are
        // re-applied; they arrive with swipe paging on.
        model.onLocationChange = { [weak self] in self?.updateNativePaging() }
        model.onSettingsApplied = { [weak self] in self?.updateNativePaging() }
        model.requestTurn = { [weak self] turn in await self?.turn(turn) }

        let center = NotificationCenter.default
        for name in [UIAccessibility.reduceMotionStatusDidChangeNotification, UIAccessibility.voiceOverStatusDidChangeNotification] {
            accessibilityObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateNativePaging() }
            })
        }
        updateNativePaging()
    }

    isolated deinit {
        if let tapObserver { model.navigator?.removeObserver(tapObserver) }
        model.onLocationChange = nil
        model.onSettingsApplied = nil
        model.requestTurn = nil
        for observer in accessibilityObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A fold or resize can make Readium rebuild its pages.
        updateNativePaging()
    }

    /// Re-applies anything that depends on the settings.
    func settingsDidChange() {
        guard currentPlan != appliedPlan else { return }
        updateNativePaging()
    }

    private var currentPlan: TurnPlan {
        TurnPlan(
            style: model.settings.pageTurn,
            flow: model.settings.flow,
            isReflowable: model.isReflowable,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )
    }

    // MARK: - Turning

    /// Turns the page with the current animation style. Returns false when
    /// the tap wasn't used: mid-animation, or with no navigator.
    @discardableResult
    func turn(_ turn: PageTurn) async -> Bool {
        guard !isTurning, let navigator = model.navigator else { return false }
        let plan = currentPlan

        guard plan.animation == .curl || plan.animation == .fade else {
            if !(await model.turn(turn, animated: plan.animation == .native(animated: true))) {
                signalEdge(of: turn)
            }
            return true
        }

        isTurning = true
        defer { isTurning = false }

        guard let before = navigator.view.snapshotView(afterScreenUpdates: false) else {
            if !(await model.turn(turn, animated: false)) { signalEdge(of: turn) }
            return true
        }
        before.frame = navigator.view.frame
        before.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(before)

        guard await model.turn(turn, animated: false) else {
            before.removeFromSuperview()
            signalEdge(of: turn)
            return true
        }
        // Give the web view a frame to draw the new page under the snapshot.
        try? await Task.sleep(for: .milliseconds(40))

        if plan.animation == .curl {
            await curl(away: before, towardRight: turn.revealsRight(rightToLeft: model.isRightToLeft))
        } else {
            await fade(away: before)
        }
        return true
    }

    /// At the first or last page, a light bump and a spoken note instead of
    /// silence.
    private func signalEdge(of turn: PageTurn) {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        let atEnd = turn.isForward(rightToLeft: model.isRightToLeft)
        UIAccessibility.post(
            notification: .announcement,
            argument: atEnd ? String(localized: "End of book") : String(localized: "Start of book")
        )
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

    /// Curls the old page off like a paper page: from the right edge when the
    /// next page is on the right, from the left edge otherwise.
    private func curl(away snapshot: UIView, towardRight: Bool) async {
        guard let navigator = model.navigator,
              let after = navigator.view.snapshotView(afterScreenUpdates: true) else {
            snapshot.removeFromSuperview()
            return
        }
        let pages = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        pages.isDoubleSided = false
        pages.view.frame = navigator.view.frame
        pages.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pages.view.isUserInteractionEnabled = false
        pages.setViewControllers([SnapshotPage(snapshot)], direction: .forward, animated: false)
        addChild(pages)
        view.addSubview(pages.view)
        pages.didMove(toParent: self)

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            pages.setViewControllers([SnapshotPage(after)], direction: towardRight ? .forward : .reverse, animated: true) { _ in
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
        let plan = currentPlan
        appliedPlan = plan
        swipeLeft.isEnabled = plan.ownsSwipes
        swipeRight.isEnabled = plan.ownsSwipes
        nativePaging.setEnabled(!plan.ownsSwipes, in: navigator.view)
    }

    private let nativePaging = NativePaging()
}

/// Switches the swipe-to-page scrolling inside a Readium navigator on or off.
///
/// Readium doesn't expose this, so it walks the view tree for horizontally
/// paging scroll views (the spread pager and each page's web view). It runs
/// again after each page change, because Readium creates web views as it goes.
@MainActor
final class NativePaging {
    /// Pans this switched off, remembered so they come back on even if
    /// Readium has since turned paging off on their scroll view.
    private let disabled = NSHashTable<UIPanGestureRecognizer>.weakObjects()

    func setEnabled(_ enabled: Bool, in root: UIView) {
        if enabled {
            for pan in disabled.allObjects { pan.isEnabled = true }
            disabled.removeAllObjects()
        } else {
            for scrollView in Self.pagingScrollViews(in: root) where scrollView.panGestureRecognizer.isEnabled {
                scrollView.panGestureRecognizer.isEnabled = false
                disabled.add(scrollView.panGestureRecognizer)
            }
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
