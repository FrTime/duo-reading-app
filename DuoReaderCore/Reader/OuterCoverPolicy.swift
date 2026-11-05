import Foundation

/// Decides when the reader shows the book's cover on iPhone Duo's outer
/// screen, and what the setting should say about it.
///
/// iOS only presents content on the outer screen while the Duo is open
/// through a camera capture accessory, and only while the app has a running
/// capture session (see docs/spikes/outer-screen-cover.md). So the cover costs
/// a camera session, and this policy keeps that session to exactly the time it
/// is useful: the setting is on, the camera is allowed, a book is open and in
/// front, and the device is open.
public enum OuterCoverPolicy {
    /// The camera permission, flattened from `AVAuthorizationStatus` plus
    /// "this device has no front camera".
    public enum CameraAccess: Sendable, Equatable {
        case notDetermined
        case authorized
        case denied
        case restricted
        case noCamera
    }

    /// The Duo's hinge, flattened from SwiftUI's `DeviceHinge`. `none` means
    /// the device has no hinge (any other iPhone).
    public enum Hinge: Sendable, Equatable {
        case none
        case closed
        case partiallyOpen
        case fullyOpen
    }

    public struct Inputs: Sendable, Equatable {
        /// The user's "Show Cover on the Outside" setting.
        public var isEnabled: Bool
        public var cameraAccess: CameraAccess
        public var hinge: Hinge
        /// The reader's scene is active (not backgrounded or behind a switcher).
        public var isActive: Bool
        /// A book is open and rendered, so there's a cover worth showing.
        public var isReaderReady: Bool

        public init(isEnabled: Bool, cameraAccess: CameraAccess, hinge: Hinge, isActive: Bool, isReaderReady: Bool) {
            self.isEnabled = isEnabled
            self.cameraAccess = cameraAccess
            self.hinge = hinge
            self.isActive = isActive
            self.isReaderReady = isReaderReady
        }
    }

    /// What the setting's footer tells the reader.
    public enum Status: Sendable, Equatable {
        /// Not an iPhone Duo; the setting is hidden.
        case unsupported
        /// The setting is off.
        case off
        /// On, but the camera prompt hasn't been answered yet.
        case needsPermission
        /// On, but camera access is denied or restricted, so it can't work.
        case blocked
        /// On and allowed; the cover shows whenever the Duo is open.
        case ready
    }

    /// Whether the camera session (and so the cover) should run right now.
    public static func shouldRunCamera(_ inputs: Inputs) -> Bool {
        inputs.isEnabled
            && inputs.cameraAccess == .authorized
            && inputs.isActive
            && inputs.isReaderReady
            && isOpen(inputs.hinge)
    }

    public static func status(_ inputs: Inputs) -> Status {
        guard inputs.hinge != .none, inputs.cameraAccess != .noCamera else { return .unsupported }
        guard inputs.isEnabled else { return .off }
        switch inputs.cameraAccess {
        case .notDetermined: return .needsPermission
        case .denied, .restricted, .noCamera: return .blocked
        case .authorized: return .ready
        }
    }

    /// The outer screen is only free for the cover while the Duo is open.
    /// Closed, the reader itself is on the outer screen.
    public static func isOpen(_ hinge: Hinge) -> Bool {
        hinge == .partiallyOpen || hinge == .fullyOpen
    }
}
