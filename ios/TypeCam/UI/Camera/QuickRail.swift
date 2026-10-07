//
//  QuickRail.swift
//  TypeCam
//

import SwiftUI

/// Left rail with FOCUS / AE / WB / ISO. Read-only in M1; the controls become interactive in M5.
struct QuickRail: View {
    let iso: Float
    let iconRotation: Angle

    var body: some View {
        VStack(spacing: 0) {
            item("FOCUS") { Image(systemName: "mountain.2.fill") }
            divider
            item("AE") { Image(systemName: "sun.max.fill") }
            divider
            item("WB") { Text("A").font(.callout.weight(.bold)) }
            divider
            item("ISO") {
                Text(iso > 0 ? "\(Int(iso.rounded()))" : "–")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .frame(width: 58)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.overlayPanel))
        .foregroundStyle(.white)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.horizontal, 10)
    }

    private func item<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(Theme.secondaryText)
            content()
                .frame(height: 20)
        }
        .padding(.vertical, 10)
        .rotationEffect(iconRotation)
        .animation(.spring(duration: 0.35), value: iconRotation)
    }
}
