import RealityKit
import SwiftUI
import UIKit

/// Draws the shelf scene, and stops drawing it when nothing is moving.
///
/// RealityKit redraws every frame while its view is on screen, which costs a
/// steady share of CPU and battery even for a still bookcase, and
/// `RealityView` has no way to pause. So this hosts an `ARView` without AR,
/// and once the scene has been still for a moment it shows a snapshot of the
/// last frame and takes the live view out of the window. Any change to the
/// scene (`ShelfScene.onActivity`) brings it straight back.
struct ShelfRenderView: UIViewRepresentable {
    let scene: ShelfScene
    var background: UIColor

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ShelfRenderHost {
        let host = ShelfRenderHost(scene: scene, background: background)
        scene.onActivity = { [weak host] in host?.wake() }
        host.wake()
        return host
    }

    func updateUIView(_ host: ShelfRenderHost, context: Context) {}

    static func dismantleUIView(_ host: ShelfRenderHost, coordinator: Coordinator) {
        host.tearDown()
    }

    final class Coordinator {}
}

/// The UIKit side: a live `ARView` and a still image of it, swapped as the
/// scene moves and settles.
final class ShelfRenderHost: UIView {
    /// How long the scene must be still before the live view is parked.
    /// Longer than any of the scene's animations.
    static let settleDelay: Duration = .milliseconds(900)

    private let arView: ARView
    private let still = UIImageView()
    private var idleTask: Task<Void, Never>?
    /// Bumped on every wake, so a snapshot that finishes after the scene
    /// moved again is thrown away.
    private var generation = 0
    private(set) var isLive = false
    /// The size the still was taken at, in points.
    private var parkedSize: CGSize?

    init(scene: ShelfScene, background: UIColor) {
        arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        super.init(frame: .zero)
        backgroundColor = background
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true

        arView.environment.background = .color(background)
        // None of the camera effects apply to a still bookcase; the scene's
        // own lights cast the shadows.
        arView.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableCameraGrain, .disableGroundingShadows]
        arView.isUserInteractionEnabled = false
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(scene.root)
        arView.scene.addAnchor(anchor)

        still.contentMode = .scaleToFill
        still.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        still.isHidden = true
        addSubview(still)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        arView.frame = bounds
        still.frame = bounds
        // A resize changes the picture; draw it live again. (Compared in
        // points: the snapshot image itself is in pixels.)
        if !isLive, parkedSize != bounds.size { wake() }
    }

    /// Something in the scene changed: draw live, and park again once it
    /// has been still for `settleDelay`.
    func wake() {
        generation += 1
        if !isLive {
            isLive = true
            arView.frame = bounds
            insertSubview(arView, belowSubview: still)
            // Keep the still up for a couple of frames, until the live view
            // has drawn, so waking never flashes.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.isLive else { return }
                self.still.isHidden = true
            }
        }
        scheduleIdle()
    }

    private func scheduleIdle() {
        idleTask?.cancel()
        let current = generation
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self, self.generation == current else { return }
            self.park(generation: current)
        }
    }

    private func park(generation current: Int) {
        guard isLive, bounds.width > 0, bounds.height > 0 else { return }
        arView.snapshot(saveToHDR: false) { [weak self] image in
            MainActor.assumeIsolated {
                guard let self, self.generation == current, self.isLive, let image else { return }
                self.still.image = image
                self.parkedSize = self.bounds.size
                self.still.isHidden = false
                self.bringSubviewToFront(self.still)
                // Out of the window, RealityKit stops drawing.
                self.arView.removeFromSuperview()
                self.isLive = false
            }
        }
    }

    func tearDown() {
        idleTask?.cancel()
        arView.removeFromSuperview()
    }
}
