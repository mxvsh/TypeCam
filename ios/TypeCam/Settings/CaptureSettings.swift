//
//  CaptureSettings.swift
//  TypeCam
//

import Foundation

nonisolated enum VideoResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case hd720, hd1080, uhd4K

    var id: Self { self }

    var width: Int32 {
        switch self {
        case .hd720: 1280
        case .hd1080: 1920
        case .uhd4K: 3840
        }
    }

    var height: Int32 {
        switch self {
        case .hd720: 720
        case .hd1080: 1080
        case .uhd4K: 2160
        }
    }

    var label: String {
        switch self {
        case .hd720: "720p"
        case .hd1080: "1080p"
        case .uhd4K: "4K"
        }
    }

    var rank: Int { Self.allCases.firstIndex(of: self)! }
}

nonisolated enum VideoCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case h264, hevc

    var id: Self { self }
    var label: String { self == .h264 ? "H.264" : "HEVC" }
}

nonisolated enum OrientationLock: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, landscape, portrait

    var id: Self { self }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .landscape: "Landscape"
        case .portrait: "Portrait"
        }
    }
}

nonisolated enum StabilizationMode: String, Codable, Sendable {
    case off, standard
}

nonisolated enum CameraPosition: String, Codable, Sendable {
    case back, front
}

nonisolated enum DimStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case blackout, dimPreview

    var id: Self { self }
    var label: String { self == .blackout ? "Blackout" : "Dim preview" }
}

/// Every user-facing setting, persisted as one JSON blob. See docs/IOS_APP.md for the spec.
/// These are *preferences*: the camera clamps them to what the active device supports
/// without writing the clamped value back.
nonisolated struct CaptureSettings: Codable, Equatable, Sendable {
    // Video
    var resolution: VideoResolution = .hd1080
    var frameRate = 30
    var codec: VideoCodec = .hevc
    var bitrateAuto = true
    var bitrateMbps: Double = 12
    var keyframeInterval: Double = 1
    var orientation: OrientationLock = .landscape
    var mirrorFront = false

    // Lens & image
    var cameraPosition: CameraPosition = .back
    var stabilization: StabilizationMode = .off
    var torchOn = false
    var torchLevel: Float = 1

    // Display & power
    var dimStyle: DimStyle = .blackout

    // Connection
    /// Name shown in OBS's device list. Empty = the system device name.
    var deviceName = ""

    static let frameRates = [24, 25, 30, 60]
    static let keyframeIntervals: [Double] = [0.5, 1, 2]
    static let bitrateRange: ClosedRange<Double> = 2...100

    /// Auto bitrate table from docs/IOS_APP.md (HEVC; H.264 gets 1.5×).
    func autoBitrateMbps(resolution: VideoResolution, frameRate: Int) -> Double {
        let high = frameRate > 30
        let hevc: Double = switch resolution {
        case .hd720: high ? 6 : 4
        case .hd1080: high ? 12 : 8
        case .uhd4K: high ? 40 : 25
        }
        return codec == .hevc ? hevc : hevc * 1.5
    }

    init() {}

    // Decode field by field with defaults so adding settings in later milestones
    // never wipes what the user already saved.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptureSettings()
        resolution = c.value(.resolution, default: d.resolution)
        frameRate = c.value(.frameRate, default: d.frameRate)
        codec = c.value(.codec, default: d.codec)
        bitrateAuto = c.value(.bitrateAuto, default: d.bitrateAuto)
        bitrateMbps = c.value(.bitrateMbps, default: d.bitrateMbps)
        keyframeInterval = c.value(.keyframeInterval, default: d.keyframeInterval)
        orientation = c.value(.orientation, default: d.orientation)
        mirrorFront = c.value(.mirrorFront, default: d.mirrorFront)
        cameraPosition = c.value(.cameraPosition, default: d.cameraPosition)
        stabilization = c.value(.stabilization, default: d.stabilization)
        torchOn = c.value(.torchOn, default: d.torchOn)
        torchLevel = c.value(.torchLevel, default: d.torchLevel)
        dimStyle = c.value(.dimStyle, default: d.dimStyle)
        deviceName = c.value(.deviceName, default: d.deviceName)
    }
}

private extension KeyedDecodingContainer {
    nonisolated func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
