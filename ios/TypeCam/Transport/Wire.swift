//
//  Wire.swift
//  TypeCam
//
//  Constants and framing for docs/PROTOCOL.md. Mirrors obs-plugin/src/protocol.h —
//  change both in the same commit.
//

import Foundation

nonisolated enum MessageType: UInt8, Sendable {
    case hello = 0x01
    case helloAck = 0x02
    case videoConfig = 0x10
    case videoFrame = 0x11
    case audioConfig = 0x20
    case audioFrame = 0x21
    case deviceStatus = 0x30
    case hostStats = 0x31
    case keyframeRequest = 0x32
    case ping = 0x40
    case pong = 0x41
    case streamState = 0x50
}

nonisolated enum Wire {
    static let port: UInt16 = 7878
    static let protocolVersion = 1
    /// Bytes "TC" on the wire (u16 little-endian 0x4354).
    static let magic: UInt16 = 0x4354
    static let headerSize = 16
    static let maxPayload = 8 << 20
    static let keyframeFlag: UInt8 = 0x01

    struct Header: Sendable {
        var type: UInt8
        var flags: UInt8
        var length: UInt32
        var pts: UInt64
    }

    static func encodeHeader(_ type: MessageType, flags: UInt8 = 0, length: Int, pts: UInt64 = 0) -> Data {
        var data = Data(capacity: headerSize)
        data.appendLE(magic)
        data.append(type.rawValue)
        data.append(flags)
        data.appendLE(UInt32(length))
        data.appendLE(pts)
        return data
    }

    /// Returns nil for a bad magic or an oversized payload — the caller must close the connection.
    static func decodeHeader(_ data: Data) -> Header? {
        guard data.count == headerSize else { return nil }
        let bytes = [UInt8](data)
        let magicValue = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        let length = bytes[4..<8].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        let pts = bytes[8..<16].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        guard magicValue == magic, length <= maxPayload else { return nil }
        return Header(type: bytes[2], flags: bytes[3], length: length, pts: pts)
    }

    /// VIDEO_CONFIG payload (binary layout in docs/PROTOCOL.md).
    static func videoConfig(_ format: VideoFormat, fps: Int, rotation: Int) -> Data {
        var data = Data()
        data.append(format.codec == .h264 ? 1 : 2)
        data.append(0)
        data.appendLE(UInt16(format.width))
        data.appendLE(UInt16(format.height))
        data.appendLE(UInt16(fps))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(rotation))
        data.append(UInt8(format.parameterSets.count))
        for set in format.parameterSets {
            data.appendLE(UInt16(set.count))
            data.append(set)
        }
        return data
    }

    static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

private extension Data {
    nonisolated mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
