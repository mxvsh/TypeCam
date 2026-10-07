//
//  CameraModel.swift
//  TypeCam
//

import AVFoundation
import Observation

/// Main-actor façade over `CameraController` for the UI. Owns settings → camera wiring,
/// rotation (via `AVCaptureDevice.RotationCoordinator`) and the stream-state button.
@Observable
final class CameraModel {
    private(set) var state = CameraState()
    private(set) var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var streamState: StreamState = .waiting
    /// True from a flip tap until the new camera's first frame is on screen.
    private(set) var isSwitchingCamera = false
    /// Increments per flip; drives the flip animation.
    private(set) var flipCount = 0
    /// Clockwise rotation OBS must apply to show frames upright (VIDEO_CONFIG.rotation, M2).
    private(set) var outputRotation = 0
    var isDimmed = false

    let store: SettingsStore
    @ObservationIgnored let frames = FrameMailbox()

    @ObservationIgnored private let controller = CameraController()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private weak var previewLayer: CALayer?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var lastLandscapeAngle: CGFloat = 0
    @ObservationIgnored private var lastPortraitAngle: CGFloat = 90
    @ObservationIgnored private var switchStartedAt: ContinuousClock.Instant?

    /// The flip animation turns edge-on at this point; the new camera may appear from here on.
    private static let flipMidpoint: Duration = .milliseconds(180)

    init(store: SettingsStore) {
        self.store = store

        let frames = frames
        frames.firstFrameHandler = { [unowned self] in
            Task { @MainActor in self.isSwitchingCamera = false }
        }
        controller.frameHandler = { sampleBuffer in
            if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
                frames.put(pixels)
            }
        }
        controller.stateHandler = { [unowned self] state in
            Task { @MainActor in self.state = state }
        }
        controller.deviceHandler = { [unowned self] device in
            nonisolated(unsafe) let device = device
            Task { @MainActor in self.deviceDidChange(device) }
        }
        store.onChange = { [weak self] settings in
            self?.controller.update(settings)
            self?.updateRotation()
        }
    }

    var settings: CaptureSettings { store.settings }

    // MARK: - Lifecycle

    func start() async {
        if authorization == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            authorization = AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard authorization == .authorized, !started else { return }
        started = true
        controller.start(with: store.settings)
    }

    func resume() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        if started { controller.resume() }
    }

    func attachPreviewLayer(_ layer: CALayer) {
        guard layer !== previewLayer else { return }
        previewLayer = layer
        rebuildRotationCoordinator()
    }

    // MARK: - Commands

    func setZoom(_ displayZoom: CGFloat) {
        controller.setDisplayZoom(displayZoom, animated: false)
    }

    func selectLens(_ lens: LensOption) {
        controller.setDisplayZoom(lens.displayZoom, animated: true)
    }

    func flipCamera() {
        guard !isSwitchingCamera else { return }
        isSwitchingCamera = true
        flipCount += 1
        switchStartedAt = .now
        frames.freeze()
        store.settings.cameraPosition = store.settings.cameraPosition == .back ? .front : .back

        // Never leave the preview frozen if the switch fails.
        let flip = flipCount
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard isSwitchingCamera, flip == flipCount else { return }
            frames.resume()
            isSwitchingCamera = false
        }
    }

    func toggleStreamPaused() {
        switch streamState {
        case .live: streamState = .paused
        case .paused: streamState = .live
        case .waiting: break
        }
    }

    // MARK: - Rotation

    private func deviceDidChange(_ device: AVCaptureDevice) {
        self.device = device
        lastLandscapeAngle = 0
        lastPortraitAngle = 90
        rebuildRotationCoordinator()
        if isSwitchingCamera { resumePreviewAfterFlip() }
    }

    /// Unfreezes the preview no earlier than the flip's midpoint, so the new camera
    /// appears while the card is edge-on.
    private func resumePreviewAfterFlip() {
        let elapsed = switchStartedAt.map { ContinuousClock.now - $0 } ?? Self.flipMidpoint
        let wait = max(.zero, Self.flipMidpoint - elapsed)
        let frames = frames
        Task {
            try? await Task.sleep(for: wait)
            frames.resume()
        }
    }

    private func rebuildRotationCoordinator() {
        rotationObservations = []
        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [unowned self] _, _ in
                Task { @MainActor in self.updateRotation() }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [unowned self] _, _ in
                Task { @MainActor in self.updateRotation() }
            },
        ]
    }

    /// Frames always stay sensor-native. This picks the rotation OBS applies (honouring the
    /// orientation lock) and the rotation the preview applies on the portrait-locked UI.
    private func updateRotation() {
        guard let coordinator = rotationCoordinator else { return }
        let horizon = coordinator.videoRotationAngleForHorizonLevelCapture
        if Int(horizon) % 180 == 0 {
            lastLandscapeAngle = horizon
        } else {
            lastPortraitAngle = horizon
        }
        let capture: CGFloat = switch store.settings.orientation {
        case .auto: horizon
        case .landscape: lastLandscapeAngle
        case .portrait: lastPortraitAngle
        }
        outputRotation = mirrorCorrected(capture)
        frames.previewRotation = mirrorCorrected(coordinator.videoRotationAngleForHorizonLevelPreview)
    }

    /// The connection mirrors around the sensor-native vertical axis. After a quarter turn that
    /// would read as an upside-down flip, so add a half turn to get a left-right mirror.
    private func mirrorCorrected(_ angle: CGFloat) -> Int {
        let degrees = Int(angle.rounded())
        let mirrored = store.settings.cameraPosition == .front && store.settings.mirrorFront
        let corrected = mirrored && degrees % 180 != 0 ? degrees + 180 : degrees
        return (corrected % 360 + 360) % 360
    }
}
