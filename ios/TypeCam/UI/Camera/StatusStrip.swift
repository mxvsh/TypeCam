//
//  StatusStrip.swift
//  TypeCam
//

import SwiftUI

/// Top bar: app name, active format, connection chip, thermal and battery.
struct StatusStrip: View {
    let format: String
    let streamState: StreamState
    let status: DeviceStatus

    var body: some View {
        HStack(spacing: 10) {
            Text("TypeCam")
                .font(.headline.weight(.bold))
            Spacer(minLength: 8)
            Text(format)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
            ConnectionChip(state: streamState)
            if status.isHot {
                Image(systemName: "thermometer.high")
                    .foregroundStyle(status.thermalState == .critical ? Theme.live : Theme.paused)
            }
            Image(systemName: status.batterySymbol)
                .font(.body)
                .foregroundStyle(status.batteryLevel < 0.2 && !status.isCharging ? Theme.live : .white)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }
}

/// Connection state as a single dot: pulsing grey while waiting, red live, amber paused.
struct ConnectionChip: View {
    let state: StreamState

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 10, height: 10)
            .padding(5)
            .background(Circle().fill(state == .waiting ? Theme.pillFill : state.color.opacity(0.25)))
            .phaseAnimator([1.0, 0.3]) { dot, opacity in
                dot.opacity(state == .waiting ? opacity : 1)
            } animation: { _ in .easeInOut(duration: 0.9) }
            .animation(.easeInOut(duration: 0.2), value: state)
            .accessibilityLabel(state.title)
    }
}
