//
//  AudioMeterView.swift
//  TypeCam
//

import SwiftUI

/// Vertical L/R meter on the camera screen. Long-press toggles mute.
struct AudioMeterView: View {
    let levels: AudioLevels
    let muted: Bool
    let iconRotation: Angle
    let onToggleMute: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(channelIndices, id: \.self) { channel in
                    LevelMeter(
                        level: levels.peaks.indices.contains(channel) ? levels.peaks[channel] : AudioLevels.floor,
                        hold: levels.holds.indices.contains(channel) ? levels.holds[channel] : AudioLevels.floor,
                        segments: 20,
                        dimmed: muted
                    )
                    .frame(width: 6)
                }
            }
            .frame(height: 150)

            Group {
                if muted {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.live)
                } else {
                    Text(channelIndices.count == 2 ? "L R" : "M")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .rotationEffect(iconRotation)
            .animation(.spring(duration: 0.35), value: iconRotation)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.overlayPanel))
        .contentShape(Rectangle())
        .onLongPressGesture(perform: onToggleMute)
        .sensoryFeedback(.impact(weight: .medium), trigger: muted)
        .accessibilityElement()
        .accessibilityLabel(muted ? "Microphone muted" : "Audio level")
        .accessibilityHint("Long-press to \(muted ? "unmute" : "mute")")
        .accessibilityAction(named: muted ? "Unmute" : "Mute", onToggleMute)
    }

    private var channelIndices: [Int] {
        Array(0..<max(1, levels.peaks.count))
    }
}
