//
//  AudioPipeline.swift
//  TypeCam
//

import Accelerate
import AVFoundation

nonisolated struct AudioPipelineSettings: Equatable, Sendable {
    var dsp = DSPSettings()
    var format: AudioFormatSetting = .pcm
    var sampleRate = 48_000
    var stereo = false
}

/// Per-channel meter values in dBFS: current peak and held peak.
nonisolated struct AudioLevels: Equatable, Sendable {
    var peaks: [Float] = []
    var holds: [Float] = []
    static let floor: Float = -60
}

/// Capture audio → float at the target rate/channels → DSP → meters/spectrum → encoder.
/// `process` runs on the capture audio queue.
nonisolated final class AudioPipeline: @unchecked Sendable {
    var levelsHandler: (@Sendable (AudioLevels) -> Void)?
    var spectrumHandler: (@Sendable ([Float]) -> Void)?
    var outputHandler: (@Sendable (EncodedAudio) -> Void)?

    private let lock = NSLock()
    private var settings = AudioPipelineSettings()
    private var spectrumEnabled = false

    // Audio-queue state.
    private var dsp = AudioDSP()
    private let encoder = AudioEncoder()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var floatFormat: AVAudioFormat?

    private var meterPeaks: [Float] = []
    private var holds: [Float] = []
    private var holdAges: [Double] = []
    private var lastMeterPublish: UInt64 = 0

    private let spectrum = SpectrumAnalyzer()
    private var lastSpectrumPublish: UInt64 = 0

    init() {
        encoder.outputHandler = { [weak self] encoded in self?.outputHandler?(encoded) }
    }

    func update(_ settings: AudioPipelineSettings) {
        lock.withLock { self.settings = settings }
    }

    func setSpectrumEnabled(_ enabled: Bool) {
        lock.withLock { spectrumEnabled = enabled }
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        let (settings, spectrumEnabled) = lock.withLock { (self.settings, self.spectrumEnabled) }
        guard let source = Self.pcmBuffer(from: sampleBuffer),
              let converted = convert(source, sampleRate: Double(settings.sampleRate)),
              let work = Self.adaptChannels(converted, to: settings.stereo ? 2 : 1),
              let data = work.floatChannelData else { return }

        let frames = Int(work.frameLength)
        let channels = (0..<Int(work.format.channelCount)).map { data[$0] }
        dsp.configure(settings.dsp, sampleRate: Float(work.format.sampleRate))
        dsp.process(channels, count: frames)

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let nanos = UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value))

        meter(channels, frames: frames, sampleRate: work.format.sampleRate)
        if spectrumEnabled {
            spectrum.append(channels[0], count: frames)
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastSpectrumPublish > 50_000_000, let bands = spectrum.bands(sampleRate: Float(work.format.sampleRate)) {
                lastSpectrumPublish = now
                spectrumHandler?(bands)
            }
        }
        encoder.encode(work, pts: nanos, setting: settings.format)
    }

    // MARK: - Conversion

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }

    /// To non-interleaved Float32 at `sampleRate`, keeping the source channel count.
    private func convert(_ buffer: AVAudioPCMBuffer, sampleRate: Double) -> AVAudioPCMBuffer? {
        let input = buffer.format
        if converter == nil || sourceFormat != input || floatFormat?.sampleRate != sampleRate {
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                             channels: input.channelCount, interleaved: false),
                  let newConverter = AVAudioConverter(from: input, to: target) else { return nil }
            converter = newConverter
            sourceFormat = input
            floatFormat = target
            encoder.reset()
        }
        guard let converter, let floatFormat else { return nil }

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / input.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    /// Mono → stereo duplicates; stereo → mono averages.
    private static func adaptChannels(_ buffer: AVAudioPCMBuffer, to channels: Int) -> AVAudioPCMBuffer? {
        let sourceChannels = Int(buffer.format.channelCount)
        if sourceChannels == channels { return buffer }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let destination = output.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        output.frameLength = buffer.frameLength
        if channels == 1 {
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<sourceChannels { sum += source[c][i] }
                destination[0][i] = sum / Float(sourceChannels)
            }
        } else {
            for c in 0..<channels { destination[c].update(from: source[0], count: frames) }
        }
        return output
    }

    // MARK: - Metering

    /// Peak meter at ~30 Hz with a 1 s hold that then falls at 20 dB/s.
    private func meter(_ channels: [UnsafeMutablePointer<Float>], frames: Int, sampleRate: Double) {
        if meterPeaks.count != channels.count {
            meterPeaks = Array(repeating: 0, count: channels.count)
            holds = Array(repeating: AudioLevels.floor, count: channels.count)
            holdAges = Array(repeating: 0, count: channels.count)
        }
        for (c, channel) in channels.enumerated() {
            var peak: Float = 0
            vDSP_maxmgv(channel, 1, &peak, vDSP_Length(frames))
            meterPeaks[c] = max(meterPeaks[c], peak)
        }

        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastMeterPublish > 33_000_000 else { return }
        let elapsed = lastMeterPublish == 0 ? 0 : Double(now - lastMeterPublish) / 1e9
        lastMeterPublish = now

        var levels = AudioLevels()
        for c in meterPeaks.indices {
            let db = max(AudioLevels.floor, 20 * log10(meterPeaks[c] + 1e-9))
            if db >= holds[c] {
                holds[c] = db
                holdAges[c] = 0
            } else {
                holdAges[c] += elapsed
                if holdAges[c] > 1 { holds[c] = max(db, holds[c] - Float(20 * elapsed)) }
            }
            levels.peaks.append(db)
            levels.holds.append(holds[c])
            meterPeaks[c] = 0
        }
        levelsHandler?(levels)
    }
}

/// 1024-point FFT of the most recent samples, grouped into log-spaced bands (0…1).
nonisolated final class SpectrumAnalyzer {
    static let bandCount = 32
    private static let log2n: vDSP_Length = 10
    private static let size = 1 << 10

    private var samples = [Float](repeating: 0, count: size)
    private var filled = 0
    private let window: [Float]
    private let setup: FFTSetup

    init() {
        var window = [Float](repeating: 0, count: Self.size)
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
        self.window = window
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func append(_ data: UnsafePointer<Float>, count: Int) {
        let n = min(count, Self.size)
        samples.removeFirst(n)
        samples.append(contentsOf: UnsafeBufferPointer(start: data + (count - n), count: n))
        filled = min(Self.size, filled + n)
    }

    func bands(sampleRate: Float) -> [Float]? {
        guard filled == Self.size else { return nil }
        let half = Self.size / 2
        var windowed = [Float](repeating: 0, count: Self.size)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(Self.size))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        let minFrequency: Float = 60
        let maxFrequency = min(16_000, sampleRate / 2)
        let binWidth = sampleRate / Float(Self.size)
        let normalization = Float(Self.size * Self.size)
        return (0..<Self.bandCount).map { band in
            let low = minFrequency * pow(maxFrequency / minFrequency, Float(band) / Float(Self.bandCount))
            let high = minFrequency * pow(maxFrequency / minFrequency, Float(band + 1) / Float(Self.bandCount))
            let first = max(1, Int(low / binWidth))
            let last = min(half - 1, max(first, Int(high / binWidth)))
            var sum: Float = 0
            for bin in first...last { sum += magnitudes[bin] }
            let power = sum / Float(last - first + 1) / normalization
            let db = 10 * log10(power + 1e-12)
            return min(1, max(0, (db + 80) / 70)) // -80…-10 dB → 0…1
        }
    }
}
