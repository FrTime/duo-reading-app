import SwiftUI
import UIKit

/// Long-press to pick up, then drag, reporting the touch location in the
/// view's own coordinates. SwiftUI's long-press gesture doesn't report where
/// the press happened, so this wraps UIKit's recogniser.
struct LongPressDragGesture: UIGestureRecognizerRepresentable {
    enum Phase {
        case began
        case changed
        case ended
        case cancelled
    }

    var minimumDuration: TimeInterval = 0.35
    var action: (Phase, CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = minimumDuration
        recognizer.allowableMovement = 12
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        recognizer.minimumPressDuration = minimumDuration
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let location = context.converter.localLocation
        switch recognizer.state {
        case .began: action(.began, location)
        case .changed: action(.changed, location)
        case .ended: action(.ended, location)
        case .cancelled, .failed: action(.cancelled, location)
        default: break
        }
    }
}
