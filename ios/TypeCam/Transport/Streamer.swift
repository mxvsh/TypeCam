//
//  Streamer.swift
//  TypeCam
//

import CoreMedia
import Foundation

nonisolated struct StreamStats: Equatable, Sendable {
    var fps: Double = 0
    var bitrateKbps = 0
    var droppedFrames = 0
}

/// Capture → encoder → server. Encodes only while a client is connected and not paused.
/// Policy (docs/PROTOCOL.md): VIDEO_CONFIG before the first keyframe and on any format or
/// rotation change; under backpressure drop until the next keyframe and force one.
nonisolated final class Streamer: @unchecked Sendable {
    var stateHandler: (@Sendable (StreamState) -> Void)?
    var statsHandler: (@Sendable (StreamStats) -> Void)?

    private let queue = DispatchQueue(label: "app.typecam.stream", qos: .userInteractive)
    private let server: StreamServer
    private let encoder = VideoEncoder()

    /// Shared with the capture queue.
    private let lock = NSLock()
    private var sending = false
    private var keyframeRequested = false
    private var encoderSettings = EncoderSettings()
    private var deviceInfo: [String: String] = [:]

    // Stream-queue state.
    private var connected = false
    private var paused = false
    private var rotation = 0
    private var frameRate = 30
    private var sentFormat: VideoFormat?
    private var sentAudioFormat: AudioStreamFormat?
    private var awaitingKeyframe = true
    private var stats = StreamStats()
    private var windowFrames = 0
    private var windowBytes = 0
    private var statsTimer: DispatchSourceTimer?

    private static let maxVideoInFlight = 3

    init() {
        server = StreamServer(queue: queue)
        server.helloInfo = { [weak self] in
            self?.lock.withLock { self?.deviceInfo } ?? [:]
        }
        server.eventHandler = { [weak self] event in self?.handle(event) }
        encoder.outputHandler = { [weak self] encoded in
            guard let self else { return }
            queue.async { self.send(encoded) }
        }
    }

    func start() {
        server.start()
        queue.async { [self] in startStatsTimer() }
    }

    /// App backgrounded: iOS will suspend us and defunct our sockets, so close them cleanly.
    func suspend() {
        server.stop()
    }

    /// App foregrounded: listen again on a fresh socket.
    func resume() {
        server.start()
    }

    // MARK: - Capture queue

    func handle(_ sampleBuffer: CMSampleBuffer) {
        let (sending, forceKeyframe, settings) = lock.withLock {
            defer { keyframeRequested = false }
            return (self.sending, keyframeRequested, encoderSettings)
        }
        if sending {
            encoder.encode(sampleBuffer, settings: settings, forceKeyframe: forceKeyframe)
        } else {
            encoder.invalidate() // no-op when already idle; frees the hardware encoder
        }
    }

    // MARK: - Controls (any thread)

    /// HELLO_ACK fields: device_name, model, app_version.
    func setDeviceInfo(_ info: [String: String]) {
        lock.withLock { deviceInfo = info }
    }

    func update(settings: EncoderSettings) {
        lock.withLock { encoderSettings = settings }
        queue.async { [self] in frameRate = settings.frameRate }
    }

    func setRotation(_ degrees: Int) {
        queue.async { [self] in
            guard degrees != rotation else { return }
            rotation = degrees
            // Rotation is metadata: resend the config, no keyframe needed.
            if let format = sentFormat { sendConfig(format) }
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [self] in
            guard connected, paused != self.paused else { return }
            self.paused = paused
            server.send(.streamState, payload: Wire.json(["state": paused ? "paused" : "live"]))
            if !paused {
                awaitingKeyframe = true
                requestKeyframe()
            }
            updateSending()
            publishState()
        }
    }

    /// Encoded audio from the audio pipeline (any thread). Audio is never dropped.
    func handleAudio(_ audio: EncodedAudio) {
        queue.async { [self] in
            guard connected, !paused else { return }
            if audio.format != sentAudioFormat {
                server.send(.audioConfig, payload: Wire.json(audio.format.configJSON))
                sentAudioFormat = audio.format
            }
            server.send(.audioFrame, pts: audio.pts, payload: audio.data)
        }
    }

    // MARK: - Stream queue

    private func handle(_ event: ServerEvent) {
        switch event {
        case .connected:
            connected = true
            sentFormat = nil
            sentAudioFormat = nil
            awaitingKeyframe = true
            stats.droppedFrames = 0
            server.send(.streamState, payload: Wire.json(["state": paused ? "paused" : "live"]))
            requestKeyframe()
        case .disconnected:
            connected = false
        case .keyframeRequested:
            awaitingKeyframe = true
            requestKeyframe()
        case .hostStats:
            break // shown in the telemetry sheet (M7)
        }
        updateSending()
        publishState()
    }

    private func send(_ encoded: EncodedVideo) {
        guard connected, !paused else { return }
        if encoded.isKeyframe {
            if let format = encoded.format, format != sentFormat {
                sendConfig(format)
            }
            awaitingKeyframe = false
        } else if awaitingKeyframe || sentFormat == nil {
            return
        }

        if !encoded.isKeyframe && server.videoInFlight >= Self.maxVideoInFlight {
            stats.droppedFrames += 1
            awaitingKeyframe = true
            requestKeyframe()
            return
        }

        server.send(.videoFrame, flags: encoded.isKeyframe ? Wire.keyframeFlag : 0, pts: encoded.pts, payload: encoded.data)
        windowFrames += 1
        windowBytes += encoded.data.count
    }

    private func sendConfig(_ format: VideoFormat) {
        server.send(.videoConfig, payload: Wire.videoConfig(format, fps: frameRate, rotation: rotation))
        sentFormat = format
    }

    private func requestKeyframe() {
        lock.withLock { keyframeRequested = true }
    }

    private func updateSending() {
        let value = connected && !paused
        lock.withLock { sending = value }
    }

    private func publishState() {
        let state: StreamState = !connected ? .waiting : paused ? .paused : .live
        stateHandler?(state)
    }

    private func startStatsTimer() {
        guard statsTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            stats.fps = Double(windowFrames)
            stats.bitrateKbps = windowBytes * 8 / 1000
            windowFrames = 0
            windowBytes = 0
            statsHandler?(stats)
        }
        timer.resume()
        statsTimer = timer
    }
}
