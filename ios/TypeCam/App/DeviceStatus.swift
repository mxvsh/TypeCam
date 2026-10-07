//
//  DeviceStatus.swift
//  TypeCam
//

import SwiftUI
import UIKit

/// Battery, thermal state and physical orientation for the camera screen.
@Observable
final class DeviceStatus {
    private(set) var batteryLevel: Float = 1
    private(set) var isCharging = false
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    /// Rotation that keeps icons upright while the UI itself stays portrait-locked.
    private(set) var iconRotation: Angle = .zero

    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    init() {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        device.beginGeneratingDeviceOrientationNotifications()

        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification,
                     UIDevice.orientationDidChangeNotification,
                     ProcessInfo.thermalStateDidChangeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    var isHot: Bool { thermalState == .serious || thermalState == .critical }

    var batterySymbol: String {
        if isCharging { return "battery.100percent.bolt" }
        return switch batteryLevel {
        case ..<0.13: "battery.0percent"
        case ..<0.38: "battery.25percent"
        case ..<0.63: "battery.50percent"
        case ..<0.88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private func refresh() {
        let device = UIDevice.current
        // -1 when unknown (simulator).
        batteryLevel = device.batteryLevel < 0 ? 1 : device.batteryLevel
        isCharging = device.batteryState == .charging || device.batteryState == .full
        thermalState = ProcessInfo.processInfo.thermalState
        switch device.orientation {
        case .portrait: iconRotation = .zero
        case .landscapeLeft: iconRotation = .degrees(90)
        case .landscapeRight: iconRotation = .degrees(-90)
        default: break // keep the last orientation for face up/down and upside-down
        }
    }
}
