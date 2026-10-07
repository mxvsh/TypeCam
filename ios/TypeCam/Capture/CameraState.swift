//
//  CameraState.swift
//  TypeCam
//

import Foundation

/// A lens pill on the camera screen, expressed in the zoom values users see (0.5, 1, 2, 3…).
nonisolated struct LensOption: Hashable, Identifiable, Sendable {
    let displayZoom: CGFloat

    var id: CGFloat { displayZoom }
    var label: String { Self.format(displayZoom) }

    static func format(_ zoom: CGFloat) -> String {
        abs(zoom.rounded() - zoom) < 0.05 ? "\(Int(zoom.rounded()))" : String(format: "%.1f", zoom)
    }
}

/// Snapshot of the camera published by `CameraController` to the UI.
nonisolated struct CameraState: Equatable, Sendable {
    var isRunning = false
    var isInterrupted = false
    var position: CameraPosition = .back

    var lenses: [LensOption] = []
    var displayZoom: CGFloat = 1
    var minDisplayZoom: CGFloat = 1
    var maxDisplayZoom: CGFloat = 1

    var availableResolutions: [VideoResolution] = []
    var availableFrameRates: [Int] = []
    var activeResolution: VideoResolution?
    var activeFrameRate = 30

    var hasTorch = false
    var supportsStabilization = false

    var audioActive = false
    var audioRoute = AudioRouteState()

    var iso: Float = 0
    var exposureDuration: Double = 0
    var aperture: Float = 0
    var lensPosition: Float = 0.5

    var supportsManualFocus = false
    var supportsManualExposure = false
    var supportsWhiteBalanceLock = false
    var isoRange: ClosedRange<Float> = 25...3200
    /// Seconds; the upper bound is capped at one frame so manual exposure never lowers the frame rate.
    var shutterRange: ClosedRange<Double> = (1.0 / 8000)...(1.0 / 30)
    var biasRange: ClosedRange<Float> = -2...2
    /// Focus and exposure locked by a long-press on the preview.
    var aeAfLocked = false

    /// The lens the current zoom sits on: the widest lens at or below the zoom.
    var activeLens: LensOption? {
        lenses.last { $0.displayZoom <= displayZoom + 0.05 } ?? lenses.first
    }
}
