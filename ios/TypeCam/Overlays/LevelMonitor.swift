//
//  LevelMonitor.swift
//  TypeCam
//

import CoreMotion
import Foundation
import Observation

/// Device roll from gravity, for the horizon level. Runs only while the level overlay is on.
@Observable
final class LevelMonitor {
    /// Clockwise device rotation in degrees: 0 portrait, 90 landscape (left side down), ±180 upside down.
    private(set) var roll: Double = 0
    /// True when the phone lies flat, where roll is meaningless.
    private(set) var isFlat = false

    @ObservationIgnored private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let gravity = data?.gravity else { return }
            isFlat = abs(gravity.z) > 0.85
            let degrees = atan2(gravity.x, -gravity.y) * 180 / .pi
            // Light smoothing so the line doesn't shimmer.
            let delta = (degrees - roll + 540).truncatingRemainder(dividingBy: 360) - 180
            roll += delta * 0.35
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    /// Tilt away from the nearest upright orientation (portrait or landscape), in degrees.
    var deviation: Double {
        let snapped = (roll / 90).rounded() * 90
        return roll - snapped
    }
}
