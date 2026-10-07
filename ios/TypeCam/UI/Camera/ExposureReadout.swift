//
//  ExposureReadout.swift
//  TypeCam
//

import SwiftUI

/// Live shutter · aperture · ISO · white balance, under the lens pills.
struct ExposureReadout: View {
    let exposureDuration: Double
    let aperture: Float
    let iso: Float

    var body: some View {
        HStack {
            value(shutter)
            value(aperture > 0 ? String(format: "f%.1f", aperture) : "–")
            value(iso > 0 ? "ISO \(Int(iso.rounded()))" : "ISO –")
            value("AWB")
        }
        .font(.footnote.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 16)
    }

    private var shutter: String {
        guard exposureDuration > 0 else { return "–" }
        if exposureDuration >= 1 { return String(format: "%.1fs", exposureDuration) }
        return "1/\(Int((1 / exposureDuration).rounded()))"
    }

    private func value(_ text: String) -> some View {
        Text(text).frame(maxWidth: .infinity)
    }
}
