//
//  VideoEncoder.swift
//  TypeCam
//

import CoreMedia
import VideoToolbox

nonisolated struct EncoderSettings: Equatable, Sendable {
    var codec: VideoCodec = .hevc
    var bitrate = 8_000_000
    var keyframeInterval: Double = 1
    var frameRate = 30
}

/// Codec + parameter sets of the stream; a change requires a new VIDEO_CONFIG.
nonisolated struct VideoFormat: Equatable, Sendable {
    var codec: VideoCodec
    var width: Int
    var height: Int
    /// SPS/PPS (H.264) or VPS/SPS/PPS (HEVC), raw NAL units without start codes.
    var parameterSets: [Data]
}

nonisolated struct EncodedVideo: Sendable {
    /// One access unit in AVCC form (4-byte big-endian NAL lengths).
    var data: Data
    var pts: UInt64
    var isKeyframe: Bool
    /// Present on keyframes.
    var format: VideoFormat?
}

/// Low-latency VideoToolbox encoder. `encode` and `invalidate` must be called from one
/// queue (the capture queue); output arrives on a VideoToolbox thread.
nonisolated final class VideoEncoder: @unchecked Sendable {
    var outputHandler: (@Sendable (EncodedVideo) -> Void)?

    private var session: VTCompressionSession?
    private var sessionCodec: VideoCodec?
    private var sessionWidth = 0
    private var sessionHeight = 0
    private var applied = EncoderSettings()

    func encode(_ sampleBuffer: CMSampleBuffer, settings: EncoderSettings, forceKeyframe: Bool) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)

        var forceKeyframe = forceKeyframe
        if session == nil || sessionCodec != settings.codec || width != sessionWidth || height != sessionHeight {
            invalidate()
            guard makeSession(codec: settings.codec, width: width, height: height) else { return }
            apply(settings, force: true)
            forceKeyframe = true
        } else if settings != applied {
            apply(settings, force: false)
        }
        guard let session else { return }

        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixels,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.emit(sample)
        }
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        sessionCodec = nil
    }

    // MARK: - Session

    private func makeSession(codec: VideoCodec, width: Int, height: Int) -> Bool {
        let type: CMVideoCodecType = codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        // Low-latency rate control isn't available for every codec/device; fall back without it.
        let specs: [CFDictionary?] = [
            [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary,
            nil,
        ]
        for spec in specs {
            var created: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(width),
                height: Int32(height),
                codecType: type,
                encoderSpecification: spec,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &created
            )
            if status == noErr, let created {
                session = created
                sessionCodec = codec
                sessionWidth = width
                sessionHeight = height
                set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
                set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
                set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
                set(kVTCompressionPropertyKey_ProfileLevel, codec == .h264
                    ? kVTProfileLevel_H264_High_AutoLevel
                    : kVTProfileLevel_HEVC_Main_AutoLevel)
                VTCompressionSessionPrepareToEncodeFrames(created)
                return true
            }
        }
        return false
    }

    private func apply(_ settings: EncoderSettings, force: Bool) {
        if force || settings.bitrate != applied.bitrate {
            set(kVTCompressionPropertyKey_AverageBitRate, settings.bitrate as CFNumber)
            // Cap bursts at 1.5× the average over one second (bytes, seconds).
            let limits = [Double(settings.bitrate) * 1.5 / 8, 1.0] as CFArray
            set(kVTCompressionPropertyKey_DataRateLimits, limits)
        }
        if force || settings.keyframeInterval != applied.keyframeInterval || settings.frameRate != applied.frameRate {
            set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, settings.keyframeInterval as CFNumber)
            set(kVTCompressionPropertyKey_MaxKeyFrameInterval,
                max(1, Int((Double(settings.frameRate) * settings.keyframeInterval).rounded())) as CFNumber)
            set(kVTCompressionPropertyKey_ExpectedFrameRate, settings.frameRate as CFNumber)
        }
        applied = settings
    }

    private func set(_ key: CFString, _ value: CFTypeRef?) {
        guard let session else { return }
        VTSessionSetProperty(session, key: key, value: value)
    }

    // MARK: - Output

    private func emit(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return }

        let isKeyframe = !Self.isNotSync(sample)
        var format: VideoFormat?
        if isKeyframe, let description = CMSampleBufferGetFormatDescription(sample) {
            format = Self.format(from: description)
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let nanos = UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value))
        outputHandler?(EncodedVideo(data: data, pts: nanos, isKeyframe: isKeyframe, format: format))
    }

    private static func isNotSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return false }
        return first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    }

    private static func format(from description: CMFormatDescription) -> VideoFormat? {
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let isHEVC = CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC

        func parameterSet(_ index: Int, _ count: UnsafeMutablePointer<Int>?) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = isHEVC
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: count, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: count, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }

        var count = 0
        guard let first = parameterSet(0, &count) else { return nil }
        var sets = [first]
        for index in 1..<max(count, 1) {
            guard let set = parameterSet(index, nil) else { return nil }
            sets.append(set)
        }
        return VideoFormat(
            codec: isHEVC ? .hevc : .h264,
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            parameterSets: sets
        )
    }
}
