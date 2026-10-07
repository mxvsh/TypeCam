//
//  CameraScreen.swift
//  TypeCam
//

import SwiftUI

/// Main screen (layout in docs/IOS_APP.md): full-screen preview, slim status bar, audio meter,
/// and the bottom control deck. The UI is portrait-locked; icons counter-rotate with the device.
struct CameraScreen: View {
    @Bindable var camera: CameraModel
    @State private var status = DeviceStatus()
    @State private var showSettings = false
    @State private var pinchStartZoom: CGFloat?
    @State private var previewSize: CGSize = .zero
    @State private var lastTouch: CGPoint = .zero
    @AppStorage("deckTab") private var deckTab: DeckTab = .zoom

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            preview

            VStack(spacing: 0) {
                StatusStrip(format: formatSummary, streamState: camera.streamState, status: status)
                if camera.state.aeAfLocked {
                    lockBadge
                }
                if camera.settings.histogramEnabled {
                    HStack {
                        HistogramView(bins: camera.histogram)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                }
                Spacer()
                if camera.state.isInterrupted {
                    interruptedBanner
                    Spacer()
                }
                ControlDeck(
                    camera: camera,
                    tab: $deckTab,
                    iconRotation: status.iconRotation,
                    onDim: { withAnimation { camera.isDimmed = true } },
                    onSettings: { showSettings = true }
                )
            }

            if camera.state.audioActive {
                HStack {
                    Spacer()
                    AudioMeterView(
                        levels: camera.audioLevels,
                        muted: camera.settings.muted,
                        iconRotation: status.iconRotation,
                        onToggleMute: camera.toggleMute
                    )
                    .padding(.trailing, 10)
                }
                .padding(.bottom, 180)
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

    /// Live preview. A camera flip turns it like a card; lens changes blur over the cut.
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
        .onGeometryChange(for: CGSize.self) { $0.size } action: { previewSize = $0 }
        .overlay {
            ZStack {
                if camera.settings.gridEnabled {
                    GridOverlay(frame: camera.frameRect(in: previewSize))
                }
                if camera.settings.levelEnabled {
                    LevelIndicator(roll: camera.level.roll, deviation: camera.level.deviation, isFlat: camera.level.isFlat)
                }
                if let indicator = camera.focusIndicator {
                    FocusSquare(indicator: indicator, onExpire: camera.clearFocusIndicator)
                }
            }
        }
        .onTapGesture(coordinateSpace: .local) { location in
            camera.focus(at: location, in: previewSize, lock: false)
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            camera.focus(at: lastTouch, in: previewSize, lock: true)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { lastTouch = $0.startLocation })
        .simultaneousGesture(pinchToZoom)
    }

    private var lockBadge: some View {
        Button(action: camera.unlockFocus) {
            Label("AE/AF LOCK", systemImage: "lock.fill")
                .font(.caption.weight(.bold))
                .kerning(0.4)
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.paused))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Unlocks focus and exposure")
        .padding(.top, 4)
        .transition(.scale.combined(with: .opacity))
    }

    private var interruptedBanner: some View {
        Label("Camera unavailable", systemImage: "video.slash.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.overlayPanel))
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
