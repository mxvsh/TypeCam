//
//  CameraScreen.swift
//  TypeCam
//

import SwiftUI

/// Main screen (layout in docs/IOS_APP.md). The UI is portrait-locked; icons counter-rotate
/// with the device like the system Camera app.
struct CameraScreen: View {
    @Bindable var camera: CameraModel
    @State private var status = DeviceStatus()
    @State private var showSettings = false
    @State private var pinchStartZoom: CGFloat?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            preview

            VStack(spacing: 0) {
                StatusStrip(format: formatSummary, streamState: camera.streamState, status: status)
                Spacer()
                if camera.state.isInterrupted {
                    interruptedBanner
                    Spacer()
                }
                controls
            }

            HStack {
                QuickRail(iso: camera.state.iso, iconRotation: status.iconRotation)
                    .padding(.leading, 12)
                Spacer()
                if camera.state.audioActive {
                    AudioMeterView(
                        levels: camera.audioLevels,
                        muted: camera.settings.muted,
                        iconRotation: status.iconRotation,
                        onToggleMute: camera.toggleMute
                    )
                    .padding(.trailing, 12)
                }
            }

            if camera.isDimmed {
                DimOverlay(style: camera.settings.dimStyle, streamState: camera.streamState) {
                    withAnimation { camera.isDimmed = false }
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettings) {
            SettingsView(camera: camera)
        }
    }

    /// Live preview. A camera flip turns it like a card: blurred and frozen on the old camera
    /// for the first half, edge-on swap, then the new camera as the blur clears.
    private var preview: some View {
        ZStack {
            MetalPreviewView(mailbox: camera.frames) { camera.attachPreviewLayer($0) }
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(camera.isSwitchingCamera ? 1 : 0)
                .animation(.easeOut(duration: camera.isSwitchingCamera ? 0.12 : 0.3), value: camera.isSwitchingCamera)
        }
        .keyframeAnimator(initialValue: 0.0, trigger: camera.flipCount) { content, angle in
            content.rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        } keyframes: { _ in
            CubicKeyframe(90, duration: 0.18)
            MoveKeyframe(-90)
            CubicKeyframe(0, duration: 0.24)
        }
        .ignoresSafeArea()
        .gesture(pinchToZoom)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            LensPills(
                lenses: camera.state.lenses,
                activeLens: camera.state.activeLens,
                zoom: camera.state.displayZoom,
                zoomRange: camera.state.minDisplayZoom...max(camera.state.minDisplayZoom, camera.state.maxDisplayZoom),
                iconRotation: status.iconRotation,
                onSelect: camera.selectLens,
                onZoom: camera.setZoom,
                onFlip: camera.flipCamera
            )

            ExposureReadout(
                exposureDuration: camera.state.exposureDuration,
                aperture: camera.state.aperture,
                iso: camera.state.iso
            )

            HStack {
                roundButton("moon.fill", label: "Dim screen") {
                    withAnimation { camera.isDimmed = true }
                }
                Spacer()
                StreamButton(state: camera.streamState, action: camera.toggleStreamPaused)
                Spacer()
                roundButton("gearshape.fill", label: "Settings") { showSettings = true }
            }
            .padding(.horizontal, 32)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var interruptedBanner: some View {
        Label("Camera unavailable", systemImage: "video.slash.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.overlayPanel))
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Theme.overlayPanel))
                .rotationEffect(status.iconRotation)
                .animation(.spring(duration: 0.35), value: status.iconRotation)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var formatSummary: String {
        let state = camera.state
        guard let resolution = state.activeResolution else { return camera.settings.codec.label }
        return "\(resolution.label) · \(state.activeFrameRate) · \(camera.settings.codec.label)"
    }

    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStartZoom ?? camera.state.displayZoom
                pinchStartZoom = start
                camera.setZoom(start * value.magnification)
            }
            .onEnded { _ in pinchStartZoom = nil }
    }
}
