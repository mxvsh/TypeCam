//
//  CameraModel.swift
//  TypeCam
//

import AVFoundation
import Observation
import UIKit

/// Main-actor façade over `CameraController` for the UI. Owns settings → camera wiring,
/// rotation (via `AVCaptureDevice.RotationCoordinator`) and the stream-state button.
@Observable
final class CameraModel {
    private(set) var state = CameraState()
    private(set) var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var streamState: StreamState = .waiting
    private(set) var streamStats = StreamStats()
    private(set) var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var audioLevels = AudioLevels()
    private(set) var spectrum: [Float] = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
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
    @ObservationIgnored private let streamer = Streamer()
    @ObservationIgnored private let audio = AudioPipeline()
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
        let streamer = streamer
        let audio = audio
        controller.audioHandler = { sampleBuffer in audio.process(sampleBuffer) }
        audio.outputHandler = { encoded in streamer.handleAudio(encoded) }
        audio.levelsHandler = { [unowned self] levels in
            Task { @MainActor in self.audioLevels = levels }
        }
        audio.spectrumHandler = { [unowned self] bands in
            Task { @MainActor in self.spectrum = bands }
        }
        controller.frameHandler = { sampleBuffer in
            if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
                frames.put(pixels)
            }
            streamer.handle(sampleBuffer)
        }
        controller.stateHandler = { [unowned self] state in
            Task { @MainActor in
                self.state = state
                self.pushEncoderSettings()
            }
        }
        streamer.stateHandler = { [unowned self] state in
            Task { @MainActor in self.streamState = state }
        }
        streamer.statsHandler = { [unowned self] stats in
            Task { @MainActor in self.streamStats = stats }
        }
        controller.deviceHandler = { [unowned self] device in
            nonisolated(unsafe) let device = device
            Task { @MainActor in self.deviceDidChange(device) }
        }
        store.onChange = { [weak self] settings in
            self?.controller.update(settings)
            self?.updateRotation()
            self?.pushEncoderSettings()
            self?.pushAudioSettings()
            self?.pushDeviceInfo()
        }
        pushEncoderSettings()
        pushAudioSettings()
        pushDeviceInfo()
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
        streamer.start()

        if microphoneAuthorization == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        controller.setMicrophoneAuthorized(microphoneAuthorization == .authorized)
    }

    func resume() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        guard started else { return }
        controller.resume()
        streamer.resume()
    }

    func suspend() {
        guard started else { return }
        streamer.suspend()
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
        case .live: streamer.setPaused(true)
        case .paused: streamer.setPaused(false)
        case .waiting: break
        }
    }

    func toggleMute() {
        store.settings.muted.toggle()
    }

    /// The spectrum costs an FFT per buffer, so it only runs while the Audio screen is visible.
    func setSpectrumVisible(_ visible: Bool) {
        audio.setSpectrumEnabled(visible)
    }

    /// Name shown in OBS: the user's choice, else the system name.
    var deviceName: String {
        let custom = store.settings.deviceName.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? UIDevice.current.name : custom
    }

    // MARK: - Streaming

    private func pushEncoderSettings() {
        let settings = store.settings
        let resolution = state.activeResolution ?? settings.resolution
        let mbps = settings.bitrateAuto
            ? settings.autoBitrateMbps(resolution: resolution, frameRate: state.activeFrameRate)
            : settings.bitrateMbps
        streamer.update(settings: EncoderSettings(
            codec: settings.codec,
            bitrate: Int(mbps * 1_000_000),
            keyframeInterval: settings.keyframeInterval,
            frameRate: state.activeFrameRate
        ))
    }

    private func pushAudioSettings() {
        let settings = store.settings
        audio.update(AudioPipelineSettings(
            dsp: DSPSettings(
                gainDB: Float(settings.inputGainDB),
                muted: settings.muted,
                preset: settings.audioPreset,
                lowCut: settings.lowCut
            ),
            format: settings.audioFormat,
            sampleRate: settings.sampleRate,
            stereo: settings.stereo
        ))
    }

    private func pushDeviceInfo() {
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        streamer.setDeviceInfo(["device_name": deviceName, "model": model, "app_version": version])
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
        streamer.setRotation(outputRotation)
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
