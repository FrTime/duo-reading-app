#if DEBUG
import AVFoundation
import OSLog
import SwiftUI
import UIKit

// Feasibility spike for #31: can the app put the current book's cover on
// the Duo's outer screen while the device is unfolded?
//
// Launch with `-coverSpike` to open this screen instead of the library. Every
// observation is printed and appended to Documents/cover-spike.log so it can be
// read back from the simulator without tapping through the UI.
//
// Throwaway code: it lives behind DEBUG and is deleted once the real feature
// (or its fallback) is built.

@MainActor
final class CoverSpikeLog: ObservableObject {
    static let shared = CoverSpikeLog()

    @Published private(set) var lines: [String] = []
    private let logger = Logger(subsystem: "com.timothymace.duoreader", category: "coverSpike")
    private let fileURL = URL.documentsDirectory.appending(path: "cover-spike.log")

    func add(_ message: String) {
        let stamp = Date.now.formatted(.dateTime.hour().minute().second())
        let line = "\(stamp) \(message)"
        lines.append(line)
        logger.notice("\(line, privacy: .public)")
        print("[coverSpike] \(line)")
        if let data = (line + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Snapshot of every screen and scene the app can see right now.
    func dumpEnvironment(reason: String) {
        add("--- environment (\(reason)) ---")
        add("UIScreen.screens.count = \(UIScreen.screens.count)")
        for (index, screen) in UIScreen.screens.enumerated() {
            add("  screen[\(index)] bounds=\(screen.bounds.size) scale=\(screen.scale) isMain=\(screen === UIScreen.main)")
        }
        let scenes = UIApplication.shared.connectedScenes
        add("connectedScenes.count = \(scenes.count)")
        for scene in scenes {
            let role = scene.session.role.rawValue
            if let windowScene = scene as? UIWindowScene {
                add("  scene role=\(role) state=\(scene.activationState.rawValue) size=\(windowScene.coordinateSpace.bounds.size) screenBounds=\(windowScene.screen.bounds.size)")
            } else {
                add("  scene role=\(role) state=\(scene.activationState.rawValue)")
            }
        }
        add("openSessions.count = \(UIApplication.shared.openSessions.count)")
    }
}

/// The content we'd like to see on the outer screen.
struct SpikeCoverView: View {
    let label: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .purple], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 64))
                Text("The Spike Book")
                    .font(.largeTitle.bold())
                Text("Cover via \(label)")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .padding()
        }
        .ignoresSafeArea()
        .onAppear { CoverSpikeLog.shared.add("SpikeCoverView(\(label)) appeared") }
        .onDisappear { CoverSpikeLog.shared.add("SpikeCoverView(\(label)) disappeared") }
    }
}

/// Owns a capture session so the camera-capture accessory has something to key off.
@MainActor
final class SpikeCamera: ObservableObject {
    @Published private(set) var isRunning = false
    let session = AVCaptureSession()
    private var configured = false

    func start() {
        let log = CoverSpikeLog.shared
        if !configured {
            session.beginConfiguration()
            // Cheapest useful session: the reader-facing camera at the lowest preset,
            // preview only. No outputs, so no frames are ever delivered to the app.
            if session.canSetSessionPreset(.low) { session.sessionPreset = .low }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video) else {
                log.add("camera: no AVCaptureDevice for .video")
                session.commitConfiguration()
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) { session.addInput(input) }
                log.add("camera: input \(device.localizedName)")
                if (try? device.lockForConfiguration()) != nil {
                    // Lowest frame rate the device supports, to keep battery use down.
                    if let range = device.activeFormat.videoSupportedFrameRateRanges.first {
                        let duration = CMTime(value: 1, timescale: CMTimeScale(max(range.minFrameRate, 1)))
                        device.activeVideoMinFrameDuration = duration
                        device.activeVideoMaxFrameDuration = duration
                        log.add("camera: frame rate \(range.minFrameRate) fps")
                    }
                    device.unlockForConfiguration()
                }
            } catch {
                log.add("camera: input failed \(error.localizedDescription)")
            }
            session.commitConfiguration()
            configured = true
        }
        let box = SessionBox(session: session)
        Task.detached {
            let running = box.start()
            await MainActor.run {
                self.isRunning = running
                CoverSpikeLog.shared.add("camera: startRunning -> isRunning=\(running)")
            }
        }
    }

    func stop() {
        let box = SessionBox(session: session)
        Task.detached {
            box.stop()
            await MainActor.run {
                self.isRunning = false
                CoverSpikeLog.shared.add("camera: stopped")
            }
        }
    }
}

/// AVCaptureSession is thread-safe for start/stop; this box lets it cross into a detached task.
/// The small visible preview a running session needs.
struct SpikeCameraPreview: UIViewRepresentable {
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
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

private final class SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    init(session: AVCaptureSession) { self.session = session }
    func start() -> Bool { session.startRunning(); return session.isRunning }
    func stop() { session.stopRunning() }
}

struct OuterScreenCoverSpikeView: View {
    @StateObject private var log = CoverSpikeLog.shared
    @StateObject private var camera = SpikeCamera()
    @State private var externalEnabled = true
    @State private var cameraAccessoryEnabled = true
    @State private var hingeDescription = "unknown"

    var body: some View {
        NavigationStack {
            List {
                Section("Hinge") {
                    Text(hingeDescription)
                }
                Section("Accessories") {
                    Toggle("External non-interactive accessory", isOn: $externalEnabled)
                    Toggle("Camera capture accessory", isOn: $cameraAccessoryEnabled)
                    Button(camera.isRunning ? "Stop camera" : "Start camera") {
                        camera.isRunning ? camera.stop() : camera.start()
                    }
                    Button("Dump screens and scenes") {
                        log.dumpEnvironment(reason: "button")
                    }
                    Button("Legacy UIWindow on the other screen") {
                        LegacyOuterWindow.shared.attempt()
                    }
                }
                Section("Log") {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Outer screen spike")
        }
        .overlay(alignment: .bottomTrailing) {
            if camera.isRunning {
                SpikeCameraPreview(session: camera.session)
                    .frame(width: 44, height: 44)
                    .clipShape(.circle)
                    .padding()
                    .accessibilityLabel("Camera preview for the outside cover")
            }
        }
        .onHingeChange { old, new in
            let status = new.hinge.map { "\($0.status)" } ?? "nil (no hinge in this hierarchy)"
            hingeDescription = status
            log.add("onHingeChange \(old.hinge.map { "\($0.status)" } ?? "nil") -> \(status)")
            log.dumpEnvironment(reason: "hinge change")
        }
        .sceneAccessory {
            ExternalNonInteractiveAccessory(isEnabled: $externalEnabled) {
                SpikeCoverView(label: "ExternalNonInteractiveAccessory")
            }
            .onAvailabilityChange { available in
                CoverSpikeLog.shared.add("ExternalNonInteractiveAccessory available=\(available)")
            }
            CameraCaptureAccessory(isEnabled: $cameraAccessoryEnabled) {
                SpikeCoverView(label: "CameraCaptureAccessory")
            }
            .onAvailabilityChange { available in
                CoverSpikeLog.shared.add("CameraCaptureAccessory available=\(available)")
            }
        }
        .onAppear {
            log.add("spike appeared")
            log.dumpEnvironment(reason: "appear")
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-autoCamera") { camera.start() }
            if args.contains("-noCameraAccessory") { cameraAccessoryEnabled = false }
            if args.contains("-toggleCameraAccessory") {
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    cameraAccessoryEnabled = false
                    log.add("toggled camera accessory OFF")
                    try? await Task.sleep(for: .seconds(5))
                    cameraAccessoryEnabled = true
                    log.add("toggled camera accessory ON")
                }
            }
            if args.contains("-legacyWindow") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    LegacyOuterWindow.shared.attempt()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.didConnectNotification)) { _ in
            log.add("UIScreen.didConnectNotification")
            log.dumpEnvironment(reason: "screen connect")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.didDisconnectNotification)) { _ in
            log.add("UIScreen.didDisconnectNotification")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.willConnectNotification)) { note in
            let role = (note.object as? UIScene)?.session.role.rawValue ?? "?"
            log.add("UIScene.willConnect role=\(role)")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { note in
            let role = (note.object as? UIScene)?.session.role.rawValue ?? "?"
            log.add("UIScene.didDisconnect role=\(role)")
        }
    }
}

/// Pre-scenes approach: put a UIWindow on a UIScreen the app's scene isn't on.
/// `UIWindow.screen`'s setter is deprecated since iOS 13; this checks whether it
/// still does anything for the Duo's other panel.
@MainActor
final class LegacyOuterWindow {
    static let shared = LegacyOuterWindow()
    private var window: UIWindow?

    func attempt() {
        let log = CoverSpikeLog.shared
        let sceneScreen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
        log.add("legacy: scene screen bounds=\(sceneScreen?.bounds.size ?? .zero)")
        guard let other = UIScreen.screens.first(where: { $0 !== sceneScreen && $0.bounds.size != sceneScreen?.bounds.size }) else {
            log.add("legacy: no screen other than the scene's (screens=\(UIScreen.screens.count))")
            return
        }
        log.add("legacy: target screen bounds=\(other.bounds.size)")
        let window = UIWindow(frame: other.bounds)
        window.screen = other
        window.rootViewController = UIHostingController(rootView: SpikeCoverView(label: "legacy UIWindow.screen"))
        window.isHidden = false
        self.window = window
        log.add("legacy: window.screen bounds=\(window.screen.bounds.size) windowScene=\(window.windowScene == nil ? "nil" : "set") isKeyWindow=\(window.isKeyWindow)")
    }
}

enum CoverSpike {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-coverSpike")
    }
}
#endif
