//
//  StreamButton.swift
//  TypeCam
//

import SwiftUI

/// The big centre button in the shutter's place. Waiting: grey with a cable glyph, disabled.
/// Live: red, tap to pause. Paused: amber pause glyph, tap to resume.
struct StreamButton: View {
    let state: StreamState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(state.color, lineWidth: 3.5)
                    .frame(width: 68, height: 68)
                inner
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state == .waiting)
        .sensoryFeedback(.impact(weight: .medium), trigger: state)
        .animation(.spring(duration: 0.3), value: state)
        .accessibilityLabel(state.title)
        .accessibilityHint(state == .live ? "Pauses the stream" : state == .paused ? "Resumes the stream" : "Connect the iPhone to OBS with a cable")
    }

    @ViewBuilder
    private var inner: some View {
        switch state {
        case .waiting:
            Image(systemName: "cable.connector")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.waiting)
                .phaseAnimator([1.0, 0.45]) { glyph, opacity in
                    glyph.opacity(opacity)
                } animation: { _ in .easeInOut(duration: 1.1) }
        case .live:
            Circle()
                .fill(Theme.live)
                .frame(width: 54, height: 54)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.paused)
        }
    }
}
