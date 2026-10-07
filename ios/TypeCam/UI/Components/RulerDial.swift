//
//  RulerDial.swift
//  TypeCam
//

import SwiftUI

/// Horizontal scrubbing ruler, as in pro camera apps: the ticks slide under a fixed centre
/// marker with a haptic click per tick. `value` is normalised to 0…1; callers map it to real units.
struct RulerDial: View {
    @Binding var value: Double
    let label: String
    var tickCount = 60
    var leadingIcon: String?
    var trailingIcon: String?
    var dimmed = false
    /// Called when a drag starts, e.g. to switch from auto to manual.
    var onBegin: (() -> Void)?

    @State private var dragStart: Double?
    private let spacing: CGFloat = 9

    var body: some View {
        HStack(spacing: 10) {
            if let leadingIcon {
                Image(systemName: leadingIcon).font(.footnote).foregroundStyle(Theme.secondaryText)
            }
            GeometryReader { geometry in
                let total = CGFloat(tickCount) * spacing
                let mid = geometry.size.width / 2
                ZStack {
                    Canvas { context, size in
                        let offset = mid - CGFloat(value) * total
                        for index in 0...tickCount {
                            let x = offset + CGFloat(index) * spacing
                            guard x >= -2, x <= size.width + 2 else { continue }
                            let major = index % 5 == 0
                            let height: CGFloat = major ? 16 : 9
                            let fade = min(1, min(x, size.width - x) / 36) // soften the edges
                            var tick = Path()
                            tick.move(to: CGPoint(x: x, y: size.height - height))
                            tick.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(tick, with: .color(.white.opacity((major ? 0.75 : 0.35) * max(0, fade))),
                                           lineWidth: major ? 1.5 : 1)
                        }
                    }
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 3, height: 26)
                        .position(x: mid, y: geometry.size.height - 13)
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .position(x: mid, y: 8)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if dragStart == nil {
                                dragStart = value
                                onBegin?()
                            }
                            let start = dragStart ?? value
                            value = min(1, max(0, start - Double(drag.translation.width / total)))
                        }
                        .onEnded { _ in dragStart = nil }
                )
            }
            if let trailingIcon {
                Image(systemName: trailingIcon).font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(height: 46)
        .opacity(dimmed ? 0.45 : 1)
        .sensoryFeedback(.selection, trigger: Int((value * Double(tickCount)).rounded()))
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAdjustableAction { direction in
            let step = 1 / Double(tickCount)
            value = min(1, max(0, value + (direction == .increment ? step : -step)))
        }
    }
}

/// Small pill button used across the deck.
struct DeckChip: View {
    let title: String
    var systemImage: String?
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).monospacedDigit()
            }
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(selected ? Theme.accent : Theme.pillFill))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
    }
}
