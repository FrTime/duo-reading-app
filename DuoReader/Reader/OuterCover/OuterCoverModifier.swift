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

    func body(content: Content) -> some View {
        content
            .sceneAccessory {
                CameraCaptureAccessory(isEnabled: isEnabled) {
                    if let book {
                        OuterCoverView(book: book)
                    }
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
/// small preview. The reader works the same without any of it.
struct OuterCoverCameraControl: ViewModifier {
    @Binding var hinge: OuterCoverPolicy.Hinge
    let camera: OuterCoverCamera
    let shouldRunCamera: Bool

    func body(content: Content) -> some View {
        content
            .onHingeChange { _, context in
                hinge = Self.hinge(from: context)
            }
            .overlay(alignment: .bottomTrailing) {
                if camera.isRunning {
                    OuterCoverCameraPreview(session: camera.session)
                        .frame(width: 32, height: 32)
                        .clipShape(.circle)
                        .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                        .padding(12)
                        .accessibilityLabel(Text("Camera on to show the cover on the outside"))
                        .accessibilityAddTraits(.isImage)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: camera.isRunning)
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
