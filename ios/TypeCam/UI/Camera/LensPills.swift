//
//  LensPills.swift
//  TypeCam
//

import SwiftUI

/// Lens selector. The active pill shows the live zoom ("1x", "1.4x"); dragging across
/// the row zooms smoothly.
struct LensPills: View {
    let lenses: [LensOption]
    let activeLens: LensOption?
    let zoom: CGFloat
    let zoomRange: ClosedRange<CGFloat>
    let iconRotation: Angle
    let onSelect: (LensOption) -> Void
    let onZoom: (CGFloat) -> Void
    let onFlip: () -> Void

    @State private var dragStartZoom: CGFloat?

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(lenses) { lens in
                    let active = lens == activeLens
                    Button {
                        onSelect(lens)
                    } label: {
                        Text(active ? LensOption.format(zoom) + "x" : lens.label)
                            .font(.system(size: active ? 13 : 12, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(active ? Theme.paused : .white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(active ? Color.black.opacity(0.55) : .clear))
                            .rotationEffect(iconRotation)
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: active)
                }
            }
            .padding(4)
            .background(Capsule().fill(Theme.overlayPanel))
            .gesture(zoomDrag)

            Button(action: onFlip) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Theme.overlayPanel))
                    .rotationEffect(iconRotation)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch camera")
        }
        .animation(.spring(duration: 0.35), value: iconRotation)
    }

    /// Horizontal drag: each 100 pt doubles or halves the zoom.
    private var zoomDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let start = dragStartZoom ?? zoom
                dragStartZoom = start
                let target = start * pow(2, value.translation.width / 100)
                onZoom(min(max(target, zoomRange.lowerBound), zoomRange.upperBound))
            }
            .onEnded { _ in dragStartZoom = nil }
    }
}
