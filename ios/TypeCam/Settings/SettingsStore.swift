//
//  SettingsStore.swift
//  TypeCam
//

import Foundation
import Observation

@Observable
final class SettingsStore {
    var settings: CaptureSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            onChange?(settings)
        }
    }

    /// Called after every change, on the main actor.
    @ObservationIgnored var onChange: ((CaptureSettings) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(CaptureSettings.self, from: data) {
            settings = saved
        } else {
            settings = CaptureSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
