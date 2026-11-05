import Testing
@testable import DuoReader

struct OuterCoverPolicyTests {
    private func inputs(
        isEnabled: Bool = true,
        cameraAccess: OuterCoverPolicy.CameraAccess = .authorized,
        hinge: OuterCoverPolicy.Hinge = .fullyOpen,
        isActive: Bool = true,
        isReaderReady: Bool = true
    ) -> OuterCoverPolicy.Inputs {
        .init(isEnabled: isEnabled, cameraAccess: cameraAccess, hinge: hinge, isActive: isActive, isReaderReady: isReaderReady)
    }

    @Test func runsWhenEverythingLinesUp() {
        #expect(OuterCoverPolicy.shouldRunCamera(inputs()))
        #expect(OuterCoverPolicy.shouldRunCamera(inputs(hinge: .partiallyOpen)))
    }

    @Test(arguments: [
        OuterCoverPolicy.Hinge.closed,
        .none,
    ])
    func neverRunsUnlessOpen(hinge: OuterCoverPolicy.Hinge) {
        #expect(!OuterCoverPolicy.shouldRunCamera(inputs(hinge: hinge)))
    }

    @Test(arguments: [
        OuterCoverPolicy.CameraAccess.notDetermined,
        .denied,
        .restricted,
        .noCamera,
    ])
    func neverRunsWithoutCameraAccess(access: OuterCoverPolicy.CameraAccess) {
        #expect(!OuterCoverPolicy.shouldRunCamera(inputs(cameraAccess: access)))
    }

    @Test func stopsWhenOffInactiveOrLoading() {
        #expect(!OuterCoverPolicy.shouldRunCamera(inputs(isEnabled: false)))
        #expect(!OuterCoverPolicy.shouldRunCamera(inputs(isActive: false)))
        #expect(!OuterCoverPolicy.shouldRunCamera(inputs(isReaderReady: false)))
    }

    @Test func statusIsHiddenOffTheDuo() {
        #expect(OuterCoverPolicy.status(inputs(hinge: .none)) == .unsupported)
        #expect(OuterCoverPolicy.status(inputs(cameraAccess: .noCamera)) == .unsupported)
    }

    @Test func statusFollowsSettingAndPermission() {
        #expect(OuterCoverPolicy.status(inputs(isEnabled: false)) == .off)
        #expect(OuterCoverPolicy.status(inputs(cameraAccess: .notDetermined)) == .needsPermission)
        #expect(OuterCoverPolicy.status(inputs(cameraAccess: .denied)) == .blocked)
        #expect(OuterCoverPolicy.status(inputs(cameraAccess: .restricted)) == .blocked)
        #expect(OuterCoverPolicy.status(inputs()) == .ready)
        // Folded still reads as ready: the cover will show once it's opened.
        #expect(OuterCoverPolicy.status(inputs(hinge: .closed)) == .ready)
    }
}
