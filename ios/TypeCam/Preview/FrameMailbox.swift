//
//  FrameMailbox.swift
//  TypeCam
//

import CoreVideo
import Foundation

/// Single-slot handoff from the capture queue to the preview renderer. The renderer always
/// draws the newest frame; older ones are dropped.
nonisolated final class FrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var rotation = 0
    private var frozen = false
    private var awaitingFrame = false

    /// Called (on the capture queue) for the first frame after `resume()`.
    var firstFrameHandler: (@Sendable () -> Void)?

    func put(_ buffer: CVPixelBuffer) {
        let first = lock.withLock {
            guard !frozen else { return false }
            pending = buffer
            defer { awaitingFrame = false }
            return awaitingFrame
        }
        if first { firstFrameHandler?() }
    }

    /// Keeps the current frame on screen and drops new ones (used while switching cameras).
    func freeze() {
        lock.withLock { frozen = true }
    }

    func resume() {
        lock.withLock {
            frozen = false
            awaitingFrame = true
        }
    }

    func take() -> CVPixelBuffer? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }

    /// Extra clockwise rotation (degrees) the preview applies to captured frames.
    var previewRotation: Int {
        get { lock.withLock { rotation } }
        set { lock.withLock { rotation = newValue } }
    }
}
