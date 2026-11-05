import ReadiumNavigator
import SwiftUI
import UIKit

/// Embeds the Readium navigator in SwiftUI and routes taps on the page.
struct NavigatorHost: UIViewControllerRepresentable {
    let model: ReaderModel

    func makeUIViewController(context: Context) -> ReaderPageViewController {
        ReaderPageViewController(model: model)
    }

    func updateUIViewController(_ controller: ReaderPageViewController, context: Context) {}
}

/// Hosts the navigator as a child view controller.
///
/// Taps are split into three zones, like Kindle: the outer quarter on each side
/// turns the page in that direction and the middle shows or hides the bars.
/// Swipes are handled by the navigator itself.
final class ReaderPageViewController: UIViewController {
    private let model: ReaderModel
    private var tapObserver: InputObservableToken?

    /// Share of the width on each side that turns pages.
    static let edgeZoneFraction: CGFloat = 0.25

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
        guard let navigator = model.navigator else { return }

        addChild(navigator)
        navigator.view.frame = view.bounds
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigator.view)
        navigator.didMove(toParent: self)

        tapObserver = navigator.addObserver(.activate { [weak self] event in
            guard let self else { return false }
            await self.handleTap(at: event.location, in: navigator.view.bounds)
            return true
        })
    }

    private func handleTap(at point: CGPoint, in bounds: CGRect) async {
        switch TapZone(point: point, in: bounds, edgeFraction: Self.edgeZoneFraction) {
        case .left:
            await model.goLeft()
        case .right:
            await model.goRight()
        case .center:
            model.isChromeVisible.toggle()
        }
    }
}

/// Which part of the page a tap landed in.
enum TapZone: Equatable {
    case left
    case center
    case right

    init(point: CGPoint, in bounds: CGRect, edgeFraction: CGFloat) {
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
