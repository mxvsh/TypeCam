//
//  HistogramAnalyzer.swift
//  TypeCam
//

import CoreVideo
import Foundation

/// Luma histogram from a sparse sample of the Y plane, about 10 times a second.
/// `process` runs on the capture video queue and is a no-op while disabled.
nonisolated final class HistogramAnalyzer: @unchecked Sendable {
    static let binCount = 64

    var handler: (@Sendable ([Float]) -> Void)?

    private let lock = NSLock()
    private var enabled = false
    private var lastRun: UInt64 = 0

    func setEnabled(_ enabled: Bool) {
        lock.withLock { self.enabled = enabled }
    }

    func process(_ pixels: CVPixelBuffer) {
        guard lock.withLock({ enabled }) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastRun > 100_000_000 else { return }
        lastRun = now

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        // Every 8th pixel of every 8th row: ~32k samples at 1080p, plenty for a display histogram.
        var bins = [Float](repeating: 0, count: Self.binCount)
        let step = 8
        for row in stride(from: 0, to: height, by: step) {
            let line = luma + row * rowBytes
            for column in stride(from: 0, to: width, by: step) {
                bins[Int(line[column]) * Self.binCount / 256] += 1
            }
        }
        // Normalise with a soft cap so one dominant tone doesn't flatten the rest.
        let sorted = bins.sorted()
        let reference = max(1, sorted[Self.binCount * 9 / 10])
        handler?(bins.map { min(1, $0 / (reference * 1.2)) })
    }
}
