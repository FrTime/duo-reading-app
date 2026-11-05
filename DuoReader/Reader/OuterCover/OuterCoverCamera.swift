@preconcurrency import AVFoundation
import Observation
import OSLog
import SwiftUI
import UIKit

/// The camera session that keeps the cover on iPhone Duo's outer screen.
///
/// iOS only shows a camera capture accessory while the app has a running
/// capture session, so the cover needs one. This is the cheapest session that
/// counts: the front camera at the `.low` preset and its lowest frame rate,
/// with no outputs. No frame ever reaches the app, and nothing is recorded or
/// saved; the only consumer is an invisible 1 pt preview layer, which iOS
/// needs in the window before it presents the accessory.
@MainActor
@Observable
final class OuterCoverCamera {
    static let shared = OuterCoverCamera()

    private(set) var isRunning = false
    private(set) var access: OuterCoverPolicy.CameraAccess = OuterCoverCamera.currentAccess()

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.timothymace.duoreader.outer-cover-camera")
    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.timothymace.duoreader", category: "OuterCover")

    /// Re-reads the permission, which can change in Settings while the app runs.
    func refreshAccess() {
        access = Self.currentAccess()
    }

    /// Shows the system camera prompt if it hasn't been answered yet.
    func requestAccess() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        refreshAccess()
    }

    func setRunning(_ shouldRun: Bool) {
        guard shouldRun != isRunning else { return }
        isRunning = shouldRun
        let session = SendableSession(session)
        let needsConfiguration = shouldRun && !isConfigured
        if needsConfiguration { isConfigured = true }
        let logger = logger
        queue.async {
            if needsConfiguration { Self.configure(session.value, logger: logger) }
            if shouldRun {
                if !session.value.isRunning { session.value.startRunning() }
            } else if session.value.isRunning {
                session.value.stopRunning()
            }
        }
    }

    private nonisolated static func configure(_ session: AVCaptureSession, logger: Logger) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.low) { session.sessionPreset = .low }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            logger.error("No front camera; the outer cover can't run")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return }
            session.addInput(input)
            try device.lockForConfiguration()
            if let slowest = device.activeFormat.videoSupportedFrameRateRanges.min(by: { $0.minFrameRate < $1.minFrameRate }) {
                let duration = CMTime(value: 1, timescale: CMTimeScale(max(slowest.minFrameRate, 1)))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        } catch {
            logger.error("Couldn't set up the outer cover camera: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func currentAccess() -> OuterCoverPolicy.CameraAccess {
        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil else {
            return .noCamera
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}

/// `AVCaptureSession` is safe to start and stop from its own serial queue.
private struct SendableSession: @unchecked Sendable {
    let value: AVCaptureSession
    init(_ value: AVCaptureSession) { self.value = value }
}

/// The preview layer a running capture session needs in the window. The reader
/// keeps it 1 pt and transparent (see `OuterCoverCameraControl`).
struct OuterCoverCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        // The layer class is fixed above, so this cast can't fail.
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
