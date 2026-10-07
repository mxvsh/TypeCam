//
//  OverlayViews.swift
//  TypeCam
//

import SwiftUI

/// Rule-of-thirds lines over the streamed frame (which may extend past the screen edges).
struct GridOverlay: View {
    let frame: CGRect

    var body: some View {
        Path { path in
            for third in [1.0 / 3, 2.0 / 3] {
                let x = frame.minX + frame.width * third
                let y = frame.minY + frame.height * third
                path.move(to: CGPoint(x: x, y: frame.minY))
                path.addLine(to: CGPoint(x: x, y: frame.maxY))
                path.move(to: CGPoint(x: frame.minX, y: y))
                path.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
        }
        .stroke(.white.opacity(0.35), lineWidth: 0.75)
        .shadow(color: .black.opacity(0.4), radius: 1)
        .allowsHitTesting(false)
    }
}

/// Compact luma histogram panel.
struct HistogramView: View {
    let bins: [Float]

    var body: some View {
        Canvas { context, size in
            guard !bins.isEmpty else { return }
            let width = size.width / CGFloat(bins.count)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in bins.enumerated() {
                let x = CGFloat(index) * width
                let y = size.height * (1 - CGFloat(value))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + width, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(.white.opacity(0.75)))
            // Clipping hints at both ends.
            if (bins.first ?? 0) > 0.6 { context.fill(Path(CGRect(x: 0, y: 0, width: 2, height: size.height)), with: .color(Theme.paused)) }
            if (bins.last ?? 0) > 0.6 { context.fill(Path(CGRect(x: size.width - 2, y: 0, width: 2, height: size.height)), with: .color(Theme.live)) }
        }
        .frame(width: 112, height: 48)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.overlayPanel))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Horizon line that stays level with the world; turns green within ±1°.
struct LevelIndicator: View {
    let roll: Double
    let deviation: Double
    let isFlat: Bool

    var body: some View {
        let level = abs(deviation) < 1
        let color: Color = level ? Color(red: 0.2, green: 0.85, blue: 0.4) : .white
        ZStack {
            // Fixed reference marks at the nearest upright orientation.
            HStack(spacing: 150) {
                Capsule().frame(width: 18, height: 2)
                Capsule().frame(width: 18, height: 2)
            }
            .foregroundStyle(.white.opacity(0.5))
            .rotationEffect(.degrees(-(roll - deviation)))
            // The horizon itself, with a gap in the middle.
            HStack(spacing: 24) {
                Capsule().frame(width: 60, height: 2)
                Capsule().frame(width: 60, height: 2)
            }
            .foregroundStyle(color)
            .rotationEffect(.degrees(-roll))
            .animation(.linear(duration: 0.05), value: roll)
        }
        .opacity(isFlat ? 0 : 1)
        .shadow(color: .black.opacity(0.5), radius: 1)
        .sensoryFeedback(.impact(weight: .light), trigger: level) { _, now in now }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
