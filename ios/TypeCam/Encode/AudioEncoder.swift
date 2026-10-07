//
//  AudioEncoder.swift
//  TypeCam
//

import AVFoundation

/// What AUDIO_CONFIG announces; a change requires a new config message.
nonisolated struct AudioStreamFormat: Equatable, Sendable {
    var isAAC: Bool
    var sampleRate: Int
    var channels: Int

    /// AAC-LC AudioSpecificConfig (2 bytes).
    var audioSpecificConfig: Data? {
        guard isAAC else { return nil }
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
        let index = UInt8(rates.firstIndex(of: sampleRate) ?? 3)
        let objectType: UInt8 = 2 // AAC-LC
        return Data([objectType << 3 | index >> 1, (index & 1) << 7 | UInt8(channels) << 3])
    }

    var configJSON: [String: Any] {
        var json: [String: Any] = [
            "format": isAAC ? "aac" : "pcm_s16le",
            "sample_rate": sampleRate,
            "channels": channels,
        ]
        if let asc = audioSpecificConfig { json["asc"] = asc.base64EncodedString() }
        return json
    }
}

nonisolated struct EncodedAudio: Sendable {
    var format: AudioStreamFormat
    var data: Data
    /// Host-clock time of the first sample, in nanoseconds.
    var pts: UInt64
}

/// Float PCM in, PCM s16le or AAC-LC packets out. Call from one queue.
nonisolated final class AudioEncoder {
    var outputHandler: ((EncodedAudio) -> Void)?

    private var format: AudioStreamFormat?
    private var aacBitrate: Int?
    private var converter: AVAudioConverter?
    private var aacFormat: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []
    private var anchorPts: UInt64 = 0
    private var inputFrames: Int64 = 0
    private var outputPackets: Int64 = 0

    /// AAC encoder delay (priming samples) to subtract from packet timestamps.
    private static let aacPriming: Int64 = 2112
    private static let aacFramesPerPacket: Int64 = 1024

    func encode(_ buffer: AVAudioPCMBuffer, pts: UInt64, setting: AudioFormatSetting) {
        let streamFormat = AudioStreamFormat(
            isAAC: setting != .pcm,
            sampleRate: Int(buffer.format.sampleRate),
            channels: Int(buffer.format.channelCount)
        )
        if streamFormat != format || setting.aacBitrate != aacBitrate {
            reset(streamFormat, bitrate: setting.aacBitrate, inputFormat: buffer.format)
            anchorPts = pts
        }
        reanchorIfDrifted(pts: pts, sampleRate: buffer.format.sampleRate)

        if streamFormat.isAAC {
            encodeAAC(buffer, format: streamFormat)
        } else {
            outputHandler?(EncodedAudio(format: streamFormat, data: Self.interleavedS16(buffer), pts: pts))
        }
        inputFrames += Int64(buffer.frameLength)
    }

    func reset() {
        format = nil
        converter = nil
        pending.removeAll()
    }

    private func reset(_ streamFormat: AudioStreamFormat, bitrate: Int?, inputFormat: AVAudioFormat) {
        format = streamFormat
        aacBitrate = bitrate
        pending.removeAll()
        inputFrames = 0
        outputPackets = 0
        converter = nil
        guard let bitrate, streamFormat.isAAC else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: streamFormat.sampleRate,
            AVNumberOfChannelsKey: streamFormat.channels,
            AVEncoderBitRateKey: bitrate,
        ]
        guard let aac = AVAudioFormat(settings: settings),
              let converter = AVAudioConverter(from: inputFormat, to: aac) else { return }
        converter.bitRate = bitrate
        self.converter = converter
        aacFormat = aac
    }

    /// The audio clock and host clock drift slightly; re-anchor sample-count timing past 20 ms.
    private func reanchorIfDrifted(pts: UInt64, sampleRate: Double) {
        let expected = Int64(anchorPts) + inputFrames * 1_000_000_000 / Int64(sampleRate)
        if abs(Int64(pts) - expected) > 20_000_000 {
            anchorPts = UInt64(max(0, Int64(pts) - inputFrames * 1_000_000_000 / Int64(sampleRate)))
        }
    }

    private func encodeAAC(_ buffer: AVAudioPCMBuffer, format streamFormat: AudioStreamFormat) {
        guard let converter, let aacFormat else { return }
        pending.append(buffer)
        while true {
            let output = AVAudioCompressedBuffer(
                format: aacFormat,
                packetCapacity: 4,
                maximumPacketSize: max(converter.maximumOutputPacketSize, 1536)
            )
            var error: NSError?
            _ = converter.convert(to: output, error: &error) { [weak self] _, status in
                guard let self, !pending.isEmpty else {
                    status.pointee = .noDataNow
                    return nil
                }
                status.pointee = .haveData
                return pending.removeFirst()
            }
            guard error == nil, output.packetCount > 0, let descriptions = output.packetDescriptions else { return }

            for index in 0..<Int(output.packetCount) {
                let description = descriptions[index]
                let data = Data(bytes: output.data.advanced(by: Int(description.mStartOffset)),
                                count: Int(description.mDataByteSize))
                let sampleIndex = outputPackets * Self.aacFramesPerPacket - Self.aacPriming
                let pts = Int64(anchorPts) + sampleIndex * 1_000_000_000 / Int64(streamFormat.sampleRate)
                outputPackets += 1
                outputHandler?(EncodedAudio(format: streamFormat, data: data, pts: UInt64(max(0, pts))))
            }
        }
    }

    private static func interleavedS16(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let channels = buffer.floatChannelData else { return Data() }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var data = Data(count: frames * channelCount * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                for channel in 0..<channelCount {
                    let sample = max(-1, min(1, channels[channel][frame]))
                    out[frame * channelCount + channel] = Int16(sample * Float(Int16.max)).littleEndian
                }
            }
        }
        return data
    }
}
