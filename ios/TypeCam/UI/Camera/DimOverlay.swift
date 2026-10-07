//
//  DimOverlay.swift
//  TypeCam
//

import SwiftUI

/// Dim mode: blackout (or a darkened preview) at minimum brightness while capture keeps running.
/// Tap anywhere to wake.
struct DimOverlay: View {
    let style: DimStyle
    let streamState: StreamState
    let onWake: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(style == .blackout ? 1 : 0.6)
            HStack(spacing: 6) {
                Circle().fill(streamState.color).frame(width: 6, height: 6)
                Text("TypeCam · \(streamState.title) · Tap to wake")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.35))
            .padding(.bottom, 24)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onWake)
        .onAppear { ScreenBrightness.dim() }
        .onDisappear { ScreenBrightness.restore() }
        .transition(.opacity)
    }
}
