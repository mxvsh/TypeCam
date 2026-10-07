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
    /// Called on the session queue just before switching to another lens on the same side
    /// (so the preview can freeze and blur over the cut). Set before `start`.
    var lensSwitchHandler: (@Sendable () -> Void)?

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
    private var cachedInputs: [String: AVCaptureDeviceInput] = [:]
    private var lensesByPosition: [CameraPosition: [PhysicalLens]] = [:]
    private var currentLens: PhysicalLens?
    private var settings = CaptureSettings()
    private var state = CameraState()
    private var exposureTimer: DispatchSourceTimer?
    private var aeAfLocked = false
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
            // Pre-build every lens's input so lens switches and flips don't pay for it.
            for position in [CameraPosition.back, .front] {
                for lens in lenses(for: position) { _ = input(for: lens.device) }
            }
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

            if newSettings.cameraPosition != old.cameraPosition, let lens = lens(for: 1, position: newSettings.cameraPosition) {
                session.beginConfiguration()
                install(lens, displayZoom: 1)
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
                if Self.exposureFocusChanged(old, newSettings) {
                    applyExposureFocus()
                }
            }
            publish()
        }
    }

    /// Tap-to-focus/expose at `point` (sensor coordinates, 0…1). `lock` = AE/AF lock (long-press).
    /// Manual focus or exposure stays manual.
    func focus(at point: CGPoint, lock: Bool) {
        sessionQueue.async { [self] in
            guard let device = videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if !(settings.focusMode == .manual && state.supportsManualFocus), device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                let mode: AVCaptureDevice.FocusMode = lock ? .autoFocus : .continuousAutoFocus
                if device.isFocusModeSupported(mode) { device.focusMode = mode }
            }
            if !(settings.exposureMode == .manual && state.supportsManualExposure), device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                let mode: AVCaptureDevice.ExposureMode = lock ? .autoExpose : .continuousAutoExposure
                if device.isExposureModeSupported(mode) { device.exposureMode = mode }
            }
            // Re-centre on scene changes, like the system Camera app, unless locked.
            device.isSubjectAreaChangeMonitoringEnabled = !lock
            aeAfLocked = lock
            state.aeAfLocked = lock
            publish()
        }
    }

    /// Clears AE/AF lock and returns to continuous auto at the centre.
    func resetFocus() {
        sessionQueue.async { [self] in
            aeAfLocked = false
            state.aeAfLocked = false
            recenter()
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

    /// Zoom in user-facing units (0.5×, 1×, 2×…). Crossing into another lens's range switches to
    /// that physical camera; within a lens, `animated` ramps smoothly.
    func setDisplayZoom(_ displayZoom: CGFloat, animated: Bool) {
        sessionQueue.async { [self] in
            guard let current = currentLens else { return }
            let zoom = min(max(displayZoom, state.minDisplayZoom), state.maxDisplayZoom)
            guard let target = lens(for: zoom, position: settings.cameraPosition) else { return }

            if target.device.uniqueID != current.device.uniqueID {
                lensSwitchHandler?()
                session.beginConfiguration()
                install(target, displayZoom: zoom)
                session.commitConfiguration()
            } else {
                let device = current.device
                let factor = min(max(zoom / current.baseZoom, device.minAvailableVideoZoomFactor), maxZoomFactor(device))
                guard (try? device.lockForConfiguration()) != nil else { return }
                if animated {
                    device.ramp(toVideoZoomFactor: factor, withRate: Self.lensRampRate)
                } else {
                    device.cancelVideoZoomRamp()
                    device.videoZoomFactor = factor
                }
                device.unlockForConfiguration()
                state.displayZoom = factor * current.baseZoom
            }
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

        if let lens = lens(for: 1, position: settings.cameraPosition) {
            install(lens, displayZoom: 1)
        }
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

    private func input(for device: AVCaptureDevice) -> AVCaptureDeviceInput? {
        if let cached = cachedInputs[device.uniqueID] { return cached }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        cachedInputs[device.uniqueID] = input
        return input
    }

    private func lenses(for position: CameraPosition) -> [PhysicalLens] {
        if let known = lensesByPosition[position] { return known }
        let discovered = PhysicalLens.discover(position)
        lensesByPosition[position] = discovered
        return discovered
    }

    /// The lens covering `zoom`: the longest lens whose base zoom is at or below it.
    private func lens(for zoom: CGFloat, position: CameraPosition) -> PhysicalLens? {
        let lenses = lenses(for: position)
        return lenses.last { $0.baseZoom <= zoom + 0.01 } ?? lenses.first
    }

    /// Physical lenses (not the virtual multi-camera) so manual ISO, shutter and focus work on every lens.
    private func install(_ lens: PhysicalLens, displayZoom: CGFloat) {
        guard let input = input(for: lens.device) else { return }
        let device = lens.device

        let previous = videoInput
        if let previous { session.removeInput(previous) }
        guard session.canAddInput(input) else {
            if let previous { session.addInput(previous) }
            return
        }
        session.addInput(input)
        videoInput = input
        currentLens = lens

        let position = settings.cameraPosition
        let all = lenses(for: position)
        state.position = position
        state.lenses = PhysicalLens.pills(for: all)
        state.hasTorch = device.hasTorch
        state.aperture = device.lensAperture

        aeAfLocked = false
        state.aeAfLocked = false
        applyFormat()
        applyConnection()
        applyTorch()
        setZoomFactorImmediately(displayZoom / lens.baseZoom)
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
        let lenses = lenses(for: settings.cameraPosition)
        let base = currentLens?.baseZoom ?? 1
        state.minDisplayZoom = lenses.first?.baseZoom ?? 1
        if let longest = lenses.last {
            state.maxDisplayZoom = min(Self.maxDisplayZoom, longest.baseZoom * longest.device.activeFormat.videoMaxZoomFactor)
        }
        state.displayZoom = device.videoZoomFactor * base
        applyExposureFocus() // limits depend on the format and frame rate
    }

    /// Focus, exposure and white balance from settings, clamped to the active format.
    private func applyExposureFocus() {
        guard let device = videoInput?.device else { return }
        let format = device.activeFormat
        let minShutter = format.minExposureDuration.seconds
        let frame = device.activeVideoMaxFrameDuration.seconds
        let maxShutter = max(minShutter, min(format.maxExposureDuration.seconds, frame > 0 ? frame : 1))
        state.supportsManualFocus = device.isLockingFocusWithCustomLensPositionSupported
        state.supportsManualExposure = device.isExposureModeSupported(.custom)
        state.supportsWhiteBalanceLock = device.isWhiteBalanceModeSupported(.locked)
        state.isoRange = format.minISO...max(format.minISO, format.maxISO)
        state.shutterRange = minShutter...maxShutter
        state.biasRange = device.minExposureTargetBias...device.maxExposureTargetBias

        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        if settings.focusMode == .manual && state.supportsManualFocus {
            device.setFocusModeLocked(lensPosition: min(max(settings.lensPosition, 0), 1))
        } else if !aeAfLocked, device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }

        if settings.exposureMode == .manual && state.supportsManualExposure {
            let iso = min(max(settings.manualISO, state.isoRange.lowerBound), state.isoRange.upperBound)
            let shutter = min(max(settings.manualShutter, minShutter), maxShutter)
            device.setExposureModeCustom(duration: CMTime(seconds: shutter, preferredTimescale: 1_000_000_000), iso: iso)
        } else {
            if !aeAfLocked, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            let bias = min(max(settings.exposureBias, state.biasRange.lowerBound), state.biasRange.upperBound)
            device.setExposureTargetBias(bias)
        }

        let whiteBalance: AVCaptureDevice.WhiteBalanceMode = settings.whiteBalance == .locked ? .locked : .continuousAutoWhiteBalance
        if device.isWhiteBalanceModeSupported(whiteBalance) {
            device.whiteBalanceMode = whiteBalance
        }
    }

    /// Continuous auto focus/exposure at the centre of the frame (manual modes untouched).
    private func recenter() {
        guard let device = videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let center = CGPoint(x: 0.5, y: 0.5)
        if !(settings.focusMode == .manual && state.supportsManualFocus) {
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        }
        if !(settings.exposureMode == .manual && state.supportsManualExposure) {
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        }
        device.isSubjectAreaChangeMonitoringEnabled = false
    }

    private static func exposureFocusChanged(_ a: CaptureSettings, _ b: CaptureSettings) -> Bool {
        a.focusMode != b.focusMode || a.lensPosition != b.lensPosition || a.exposureMode != b.exposureMode
            || a.exposureBias != b.exposureBias || a.manualISO != b.manualISO
            || a.manualShutter != b.manualShutter || a.whiteBalance != b.whiteBalance
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
        state.displayZoom = clamped * (currentLens?.baseZoom ?? 1)
    }

    private func maxZoomFactor(_ device: AVCaptureDevice) -> CGFloat {
        min(device.maxAvailableVideoZoomFactor, Self.maxDisplayZoom / (currentLens?.baseZoom ?? 1))
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
        // After a tap-to-focus, drift back to centre when the scene changes.
        observers.append(center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            sessionQueue.async {
                guard !self.aeAfLocked else { return }
                self.recenter()
            }
        })
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
            let lens = device.lensPosition
            guard iso != state.iso || duration != state.exposureDuration || lens != state.lensPosition else { return }
            state.iso = iso
            state.exposureDuration = duration
            state.lensPosition = lens
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
}

/// One physical camera and the user-facing zoom it starts at (0.5× ultra-wide, 1× wide, 4× tele…).
nonisolated struct PhysicalLens: @unchecked Sendable {
    let device: AVCaptureDevice
    let baseZoom: CGFloat

    /// Uses the virtual multi-camera only to learn each lens's base zoom, then returns its physical
    /// constituents, which support custom exposure and lens position.
    static func discover(_ position: CameraPosition) -> [PhysicalLens] {
        let avPosition: AVCaptureDevice.Position = position == .back ? .back : .front
        if position == .back {
            let virtualTypes: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]
            let virtuals = AVCaptureDevice.DiscoverySession(deviceTypes: virtualTypes, mediaType: .video, position: .back).devices
            if let virtual = virtualTypes.lazy.compactMap({ type in virtuals.first { $0.deviceType == type } }).first {
                let multiplier = virtual.displayVideoZoomFactorMultiplier
                let factors = [virtual.minAvailableVideoZoomFactor]
                    + virtual.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
                return zip(virtual.constituentDevices, factors)
                    .map { PhysicalLens(device: $0, baseZoom: ($1 * multiplier * 10).rounded() / 10) }
                    .sorted { $0.baseZoom < $1.baseZoom }
            }
        }
        let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: avPosition)
        return wide.map { [PhysicalLens(device: $0, baseZoom: 1)] } ?? []
    }

    /// Lens pills: each lens's base zoom, plus a 2× crop of the main lens when no lens sits near 2×.
    static func pills(for lenses: [PhysicalLens]) -> [LensOption] {
        var zooms = lenses.map(\.baseZoom)
        if let main = lenses.first(where: { $0.baseZoom == 1 }),
           main.device.position == .back,
           !zooms.contains(where: { abs($0 - 2) < 0.5 }),
           main.device.activeFormat.videoMaxZoomFactor >= 2 {
            zooms.append(2)
        }
        return Set(zooms).sorted().map(LensOption.init(displayZoom:))
    }
}
