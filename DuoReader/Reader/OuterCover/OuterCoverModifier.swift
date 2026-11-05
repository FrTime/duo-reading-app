import OSLog
import SwiftUI

/// Registers the camera capture accessory that puts the open book's cover on
/// iPhone Duo's outer screen: the only way iOS lets an app draw there while
/// the Duo is open.
///
/// It sits on the window's root view, not the reader: the reader is a
/// full-screen presentation, and a registration inside a presentation never
/// reaches the scene (checked in the Duo simulator). The system shows the
/// content only while a capture session runs, which `OuterCoverCameraControl`
/// in the reader manages.
struct OuterCoverAccessory: ViewModifier {
    /// The book open in the reader, if any.
    let book: Book?
    @AppStorage(OuterCoverSettingsSection.storageKey) private var isSettingOn = false
    @Environment(\.scenePhase) private var scenePhase
    /// Off while the app is away and for a moment after it returns.
    @State private var isPaused = false
    /// Bumped on every phase change, so a late unpause can tell it's stale.
    @State private var phaseChanges = 0
    private static let logger = Logger(subsystem: "com.timothymace.duoreader", category: "OuterCover")

    func body(content: Content) -> some View {
        content
            .sceneAccessory {
                // Dropped from the builder while paused, so the system sees a
                // fresh registration when it comes back.
                if !isPaused {
                    CameraCaptureAccessory(isEnabled: isEnabled) {
                        if let book {
                            OuterCoverView(book: book)
                        }
                    }
                    .onAvailabilityChange { available in
                        Self.logger.debug("Outer cover accessory available: \(available)")
                    }
                }
            }
            // After a trip to the background, the system reconnects the
            // accessory scene but never mounts its content again, so the
            // outer screen shows a blank page colour (seen on a real Duo and
            // reproduced in the simulator). Toggling `isEnabled` or the
            // content's identity doesn't help; a fresh registration does. So
            // drop the accessory while away and register it again shortly
            // after the app is active and the capture session has restarted.
            .onChange(of: scenePhase) { _, phase in
                phaseChanges += 1
                switch phase {
                case .background:
                    isPaused = true
                case .active where isPaused:
                    let change = phaseChanges
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        // Still active, with no trip away since?
                        if change == phaseChanges { isPaused = false }
                    }
                default:
                    break
                }
            }
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { isSettingOn && book != nil },
            set: { _ in }
        )
    }
}

/// The reader's half of the outer cover: tracks the hinge, starts and stops
/// the minimal camera session the accessory needs, and shows that session's
/// invisible preview layer. The reader works the same without any of it.
struct OuterCoverCameraControl: ViewModifier {
    @Binding var hinge: OuterCoverPolicy.Hinge
    let camera: OuterCoverCamera
    let shouldRunCamera: Bool

    func body(content: Content) -> some View {
        content
            .onHingeChange { _, context in
                hinge = Self.hinge(from: context)
            }
            .background(alignment: .bottomTrailing) {
                // iOS only presents the accessory while a preview of the
                // running session is in the window (with no preview layer the
                // outer screen stays dark on a real Duo). A 1 pt, fully
                // transparent preview satisfies that without showing anyone a
                // selfie. The system's camera indicator still shows.
                if camera.isRunning {
                    OuterCoverCameraPreview(session: camera.session)
                        .frame(width: 1, height: 1)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: shouldRunCamera, initial: true) { _, run in
                camera.setRunning(run)
            }
    }

    private static func hinge(from context: DeviceHingeContext) -> OuterCoverPolicy.Hinge {
        guard let status = context.hinge?.status else { return .none }
        switch status {
        case .closed: return .closed
        case .partiallyOpen: return .partiallyOpen
        case .fullyOpen: return .fullyOpen
        default: return .none
        }
    }
}
