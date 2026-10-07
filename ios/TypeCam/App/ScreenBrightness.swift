//
//  ScreenBrightness.swift
//  TypeCam
//

import UIKit

/// Lowers screen brightness for dim mode and restores the user's level afterwards.
enum ScreenBrightness {
    private static var saved: CGFloat?

    static func dim() {
        guard saved == nil, let screen else { return }
        saved = screen.brightness
        screen.brightness = 0.01
    }

    static func restore() {
        guard let level = saved, let screen else { return }
        screen.brightness = level
        saved = nil
    }

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .screen
    }
}
