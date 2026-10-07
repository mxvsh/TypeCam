//
//  StreamButton.swift
//  TypeCam
//

import SwiftUI

/// The big centre button in the shutter's place. Waiting: grey and disabled.
/// Live: red, tap to pause. Paused: amber, tap to resume.
struct StreamButton: View {
    let state: StreamState
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .stroke(state.color, lineWidth: 4)
                        .frame(width: 76, height: 76)
                    inner
                }
                .frame(width: 80, height: 80)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(state == .waiting)
            .sensoryFeedback(.impact(weight: .medium), trigger: state)
            .accessibilityLabel(state.title)
            .accessibilityHint(state == .live ? "Pauses the stream" : state == .paused ? "Resumes the stream" : "")

            Text(state.title)
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(state == .waiting ? Theme.secondaryText : state.color)
        }
        .animation(.spring(duration: 0.3), value: state)
    }

    @ViewBuilder
    private var inner: some View {
        switch state {
        case .waiting:
            Circle()
                .fill(.white.opacity(0.18))
                .frame(width: 62, height: 62)
                .phaseAnimator([0.9, 1.0]) { circle, scale in
                    circle.scaleEffect(scale)
                } animation: { _ in .easeInOut(duration: 1.1) }
        case .live:
            Circle()
                .fill(Theme.live)
                .frame(width: 62, height: 62)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.paused)
        }
    }
}
