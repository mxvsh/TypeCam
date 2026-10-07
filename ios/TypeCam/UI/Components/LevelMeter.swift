//
//  LevelMeter.swift
//  TypeCam
//

import SwiftUI

/// Segmented peak meter (-60…0 dBFS): green, yellow from -12 dB, red from -6 dB, with a held peak segment.
struct LevelMeter: View {
    enum Axis { case vertical, horizontal }

    let level: Float
    let hold: Float
    var axis: Axis = .vertical
    var segments = 24
    var dimmed = false

    var body: some View {
        let layout = axis == .vertical
            ? AnyLayout(VStackLayout(spacing: 2))
            : AnyLayout(HStackLayout(spacing: 2))
        layout {
            ForEach(0..<segments, id: \.self) { index in
                // Vertical meters fill bottom-up, so draw the top segment first.
                let segment = axis == .vertical ? segments - 1 - index : index
                let threshold = AudioLevels.floor + Float(segment) * (-AudioLevels.floor / Float(segments))
                let lit = level > threshold
                let held = !lit && hold > threshold && hold <= threshold - AudioLevels.floor / Float(segments)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color(for: threshold).opacity(dimmed ? 0.35 : lit || held ? 1 : 0.15))
            }
        }
        .animation(.linear(duration: 0.05), value: level)
    }

    private func color(for threshold: Float) -> Color {
        if threshold >= -6 { return Color(red: 1, green: 0.27, blue: 0.23) }
        if threshold >= -12 { return Color(red: 1, green: 0.84, blue: 0.04) }
        return Color(red: 0.2, green: 0.85, blue: 0.4)
    }
}

/// Bars for the Audio screen's spectrum display (values 0…1), green → yellow → red with height.
struct SpectrumView: View {
    let bands: [Float]

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(bands.indices, id: \.self) { index in
                    let value = CGFloat(bands[index])
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.2, green: 0.85, blue: 0.4), Color(red: 1, green: 0.84, blue: 0.04), Color(red: 1, green: 0.27, blue: 0.23)],
                            startPoint: .bottom, endPoint: .top
                        ))
                        .frame(height: max(3, value * geometry.size.height))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .animation(.linear(duration: 0.08), value: bands)
        }
    }
}
