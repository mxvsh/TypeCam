//
//  CameraController.swift
//  TypeCam
//

import AVFoundation

/// Owns the `AVCaptureSession`. All session and device work runs on `sessionQueue`;
/// frames are delivered on `videoQueue`. Never touches the main actor.
nonisolated final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Called on the video queue for every captured frame. Set before `start`.
    var frameHandler: (@Sendable (CMSampleBuffer) -> Void)?
    /// Called on the audio queue for every captured audio buffer. Set before `start`.
    var audioHandler: (@Sendable (CMSampleBuffer) -> Void)?
    /// Called on the session queue whenever the published state changes. Set before `start`.
    var stateHandler: (@Sendable (CameraState) -> Void)?
    /// Called on the session queue after the active capture device changes. Set before `start`.
    var deviceHandler: (@Sendable (AVCaptureDevice) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.typecam.session")
    private let videoQueue = DispatchQueue(label: "app.typecam.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioQueue = DispatchQueue(label: "app.typecam.audio", qos: .userInteractive)
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioInput: AVCaptureDeviceInput?
    private var microphoneAuthorized = false

    // Session-queue state.
    private var videoInput: AVCaptureDeviceInput?
    private var cachedInputs: [CameraPosition: AVCaptureDeviceInput] = [:]
    private var settings = CaptureSettings()
    private var state = CameraState()
    private var zoomMultiplier: CGFloat = 1
    private var exposureTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    private static let maxDisplayZoom: CGFloat = 15
    private static let lensRampRate: Float = 6

    // MARK: - Lifecycle

    func start(with settings: CaptureSettings) {
        sessionQueue.async { [self] in
            self.settings = settings
            configureSession()
            observeSession()
            session.startRunning()
            startExposurePolling()
            state.isRunning = session.isRunning
            publish()
            // Pre-build the other camera's input so the first flip doesn't pay for it.
            _ = input(for: settings.cameraPosition == .back ? .front : .back)
        }
    }

    /// Restarts the session if the system stopped it (e.g. after returning from background).
    func resume() {
        sessionQueue.async { [self] in
            guard videoInput != nil, !session.isRunning else { return }
            session.startRunning()
            state.isRunning = session.isRunning
            publish()
        }
    }

    // MARK: - Commands

    func update(_ newSettings: CaptureSettings) {
        sessionQueue.async { [self] in
            let old = settings
            settings = newSettings
            guard videoInput != nil else { return }

            if Self.audioRoutingChanged(old, newSettings) {
                session.beginConfiguration()
                applyAudio()
                session.commitConfiguration()
            }

            if newSettings.cameraPosition != old.cameraPosition {
                session.beginConfiguration()
                installInput(for: newSettings.cameraPosition)
                session.commitConfiguration()
            } else {
                if newSettings.resolution != old.resolution || newSettings.frameRate != old.frameRate {
                    applyFormat()
                }
                if newSettings.mirrorFront != old.mirrorFront || newSettings.stabilization != old.stabilization {
                    applyConnection()
                }
                if newSettings.torchOn != old.torchOn || newSettings.torchLevel != old.torchLevel {
                    applyTorch()
                }
            }
            publish()
        }
    }

    func setMicrophoneAuthorized(_ authorized: Bool) {
        sessionQueue.async { [self] in
            guard authorized != microphoneAuthorized else { return }
            microphoneAuthorized = authorized
            guard videoInput != nil else { return }
            session.beginConfiguration()
            applyAudio()
            session.commitConfiguration()
            publish()
        }
    }

    /// Zoom in user-facing units (0.5×, 1×, 2×…). `animated` ramps smoothly, as for lens taps.
    func setDisplayZoom(_ displayZoom: CGFloat, animated: Bool) {
        sessionQueue.async { [self] in
            guard let device = videoInput?.device else { return }
            let factor = min(max(displayZoom / zoomMultiplier, device.minAvailableVideoZoomFactor), maxZoomFactor(device))
            do {
                try device.lockForConfiguration()
                if animated {
                    device.ramp(toVideoZoomFactor: factor, withRate: Self.lensRampRate)
                } else {
                    device.cancelVideoZoomRamp()
                    device.videoZoomFactor = factor
                }
                device.unlockForConfiguration()
            } catch {
                return
            }
            state.displayZoom = factor * zoomMultiplier
            publish()
        }
    }

    // MARK: - Configuration

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Audio is owned by AVAudioEngine (M4), not the capture session.
        session.automaticallyConfiguresApplicationAudioSession = false

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        installInput(for: settings.cameraPosition)
        applyAudio()
    }

    /// Mic input on the same session as video: same host clock, ~20 ms buffers.
    private func applyAudio() {
        if settings.sendAudio && microphoneAuthorized {
            state.audioRoute = AudioRouting.configure(settings)
            if audioInput == nil,
               let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
            }
            if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
                audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
                session.addOutput(audioOutput)
            }
        } else if let audioInput {
            session.removeInput(audioInput)
            self.audioInput = nil
        }
        state.audioActive = audioInput != nil
    }

    private static func audioRoutingChanged(_ a: CaptureSettings, _ b: CaptureSettings) -> Bool {
        a.sendAudio != b.sendAudio || a.audioInputID != b.audioInputID || a.micPosition != b.micPosition
            || a.polarPattern != b.polarPattern || a.sampleRate != b.sampleRate || a.stereo != b.stereo
    }

    private func input(for position: CameraPosition) -> AVCaptureDeviceInput? {
        if let cached = cachedInputs[position] { return cached }
        guard let device = Self.bestDevice(for: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        cachedInputs[position] = input
        return input
    }

    private func installInput(for position: CameraPosition) {
        guard let input = input(for: position) else { return }
        let device = input.device

        let previous = videoInput
        if let previous { session.removeInput(previous) }
        guard session.canAddInput(input) else {
            if let previous { session.addInput(previous) }
            return
        }
        session.addInput(input)
        videoInput = input

        zoomMultiplier = device.displayVideoZoomFactorMultiplier
        state.position = position
        state.lenses = Self.lenses(for: device, multiplier: zoomMultiplier)
        state.hasTorch = device.hasTorch
        state.aperture = device.lensAperture

        applyFormat()
        applyConnection()
        applyTorch()
        setZoomFactorImmediately(1 / zoomMultiplier) // start on the main (1×) lens
        deviceHandler?(device)
    }

    private func applyFormat() {
        guard let device = videoInput?.device else { return }

        let formats = device.formats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        func candidates(_ resolution: VideoResolution) -> [AVCaptureDevice.Format] {
            formats.filter {
                let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return size.width == resolution.width && size.height == resolution.height
            }
        }
        func supports(_ format: AVCaptureDevice.Format, _ fps: Int) -> Bool {
            format.videoSupportedFrameRateRanges.contains { Double(fps) >= $0.minFrameRate && Double(fps) <= $0.maxFrameRate }
        }

        let resolutions = VideoResolution.allCases.filter { !candidates($0).isEmpty }
        guard !resolutions.isEmpty else { return }
        let resolution = resolutions.last { $0.rank <= settings.resolution.rank } ?? resolutions[0]

        let resolutionFormats = candidates(resolution)
        let rates = CaptureSettings.frameRates.filter { fps in resolutionFormats.contains { supports($0, fps) } }
        let fps = rates.last { $0 <= settings.frameRate } ?? rates.first ?? 30
        guard let format = resolutionFormats.first(where: { supports($0, fps) }) else { return }

        let zoom = device.videoZoomFactor
        do {
            try device.lockForConfiguration()
            if device.activeFormat != format {
                device.activeFormat = format
            }
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.videoZoomFactor = min(max(zoom, device.minAvailableVideoZoomFactor), maxZoomFactor(device))
            device.unlockForConfiguration()
        } catch {
            return
        }

        state.availableResolutions = resolutions
        state.availableFrameRates = rates
        state.activeResolution = resolution
        state.activeFrameRate = fps
        state.minDisplayZoom = device.minAvailableVideoZoomFactor * zoomMultiplier
        state.maxDisplayZoom = maxZoomFactor(device) * zoomMultiplier
        state.displayZoom = device.videoZoomFactor * zoomMultiplier
    }

    private func applyConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        // Frames stay in the sensor's native landscape orientation. Display rotation travels
        // as metadata (VIDEO_CONFIG.rotation), so turning the phone never re-rotates the
        // pipeline, glitches the preview or restarts the encoder.
        if connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = settings.cameraPosition == .front && settings.mirrorFront
        }
        state.supportsStabilization = connection.isVideoStabilizationSupported
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = settings.stabilization == .standard ? .standard : .off
        }
    }

    private func applyTorch() {
        guard let device = videoInput?.device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if settings.torchOn, device.isTorchAvailable {
                let level = min(max(settings.torchLevel, 0.05), AVCaptureDevice.maxAvailableTorchLevel)
                try device.setTorchModeOn(level: level)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        } catch {}
    }

    private func setZoomFactorImmediately(_ factor: CGFloat) {
        guard let device = videoInput?.device else { return }
        let clamped = min(max(factor, device.minAvailableVideoZoomFactor), maxZoomFactor(device))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            return
        }
        state.displayZoom = clamped * zoomMultiplier
    }

    private func maxZoomFactor(_ device: AVCaptureDevice) -> CGFloat {
        min(device.maxAvailableVideoZoomFactor, Self.maxDisplayZoom / zoomMultiplier)
    }

    // MARK: - Observation

    private func observeSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] note in
            guard let self else { return }
            let name = note.name
            sessionQueue.async {
                switch name {
                case AVCaptureSession.wasInterruptedNotification:
                    self.state.isInterrupted = true
                case AVCaptureSession.interruptionEndedNotification:
                    self.state.isInterrupted = false
                case AVCaptureSession.runtimeErrorNotification:
                    // Media services reset or similar: try to come back.
                    if !self.session.isRunning { self.session.startRunning() }
                default:
                    break
                }
                self.state.isRunning = self.session.isRunning
                self.publish()
            }
        }
        for name in [AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.interruptionEndedNotification,
                     AVCaptureSession.runtimeErrorNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: nil, using: update))
        }
        // Headphones/Bluetooth mics coming and going change the available inputs.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            sessionQueue.async {
                guard self.audioInput != nil else { return }
                self.state.audioRoute = AudioRouting.currentState()
                self.publish()
            }
        })
    }

    /// ISO and shutter change continuously in auto exposure; poll them for the readout.
    private func startExposurePolling() {
        guard exposureTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, let device = videoInput?.device else { return }
            let iso = device.iso
            let duration = device.exposureDuration.seconds
            guard iso != state.iso || duration != state.exposureDuration else { return }
            state.iso = iso
            state.exposureDuration = duration
            publish()
        }
        timer.resume()
        exposureTimer = timer
    }

    private func publish() {
        stateHandler?(state)
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            audioHandler?(sampleBuffer)
        } else {
            frameHandler?(sampleBuffer)
        }
    }

    // MARK: - Device discovery

    /// Prefer virtual multi-lens devices so zoom crosses lenses seamlessly, like the system Camera app.
    static func bestDevice(for position: CameraPosition) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: position == .back ? .back : .front
        ).devices
        return types.lazy.compactMap { type in devices.first { $0.deviceType == type } }.first
    }

    /// Lens pills: each physical lens's switch-over point, plus a 2× crop of the main lens when
    /// no physical lens sits near 2×.
    static func lenses(for device: AVCaptureDevice, multiplier: CGFloat) -> [LensOption] {
        let factors = [device.minAvailableVideoZoomFactor]
            + device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        var zooms = factors.map { ($0 * multiplier * 10).rounded() / 10 }
        if device.position == .back,
           zooms.contains(1),
           !zooms.contains(where: { abs($0 - 2) < 0.5 }),
           2 / multiplier <= device.maxAvailableVideoZoomFactor {
            zooms.append(2)
        }
        return Set(zooms).sorted().map(LensOption.init(displayZoom:))
    }
}
