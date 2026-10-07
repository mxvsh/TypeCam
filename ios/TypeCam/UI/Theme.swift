//
//  Theme.swift
//  TypeCam
//

import SwiftUI

/// Dark creator palette (docs/IOS_APP.md): near-black surfaces, one blue accent,
/// red/amber reserved for stream state.
enum Theme {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.07)
    static let accent = Color(red: 0.184, green: 0.478, blue: 1.0)
    static let live = Color(red: 1.0, green: 0.23, blue: 0.19)
    static let paused = Color(red: 1.0, green: 0.72, blue: 0.0)
    static let waiting = Color.white.opacity(0.45)

    /// Translucent panel behind controls floating over the preview.
    static let overlayPanel = Color.black.opacity(0.45)
    static let pillFill = Color.white.opacity(0.08)
    static let secondaryText = Color.white.opacity(0.6)
}

extension StreamState {
    var color: Color {
        switch self {
        case .waiting: Theme.waiting
        case .live: Theme.live
        case .paused: Theme.paused
        }
    }

    var title: String {
        switch self {
        case .waiting: "Waiting for OBS"
        case .live: "Live"
        case .paused: "Paused"
        }
    }
}
