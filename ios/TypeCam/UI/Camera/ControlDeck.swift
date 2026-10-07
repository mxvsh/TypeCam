//
//  ControlDeck.swift
//  TypeCam
//

import AVFoundation
import SwiftUI

enum DeckTab: String, CaseIterable, Identifiable {
    case zoom, focus, exposure, whiteBalance, audio, assist

    var id: Self { self }

    var title: String {
        switch self {
        case .zoom: "ZOOM"
        case .focus: "FOCUS"
        case .exposure: "EXPOSURE"
        case .whiteBalance: "WB"
        case .audio: "AUDIO"
        case .assist: "ASSIST"
        }
    }
}

/// Bottom control deck: tabs with live values, one control area that slides left/right between
/// tabs, and the dim / stream / settings row. Every adjustment lives here.
struct ControlDeck: View {
    @Bindable var camera: CameraModel
    @Binding var tab: DeckTab
    let iconRotation: Angle
    let onDim: () -> Void
    let onSettings: () -> Void

    @State private var forward = true
    @State private var manualDial: ManualDial = .iso
    @Namespace private var underline

    private enum ManualDial { case iso, shutter }

    private var settings: CaptureSettings { camera.settings }
    private var state: CameraState { camera.state }

    var body: some View {
        VStack(spacing: 12) {
            tabBar
            ZStack {
                content
                    .id(tab)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                    ))
            }
            .frame(height: 88)
            .padding(.horizontal, 16)
            .clipped()
            bottomRow
        }
        .padding(.top, 12)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                )
                .ignoresSafeArea(edges: .bottom)
        )
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DeckTab.allCases) { item in
                Button { select(item) } label: {
                    VStack(spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 10, weight: .bold))
                            .kerning(0.4)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(item == tab ? .white : Theme.secondaryText)
                        Text(value(for: item))
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(highlighted(item) ? Theme.accent : (item == tab ? .white : .white.opacity(0.7)))
                        ZStack {
                            if item == tab {
                                Capsule().fill(Theme.accent).frame(width: 18, height: 3)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                        .frame(height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title), \(value(for: item))")
                .accessibilityAddTraits(item == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .sensoryFeedback(.selection, trigger: tab)
        .gesture(
            DragGesture(minimumDistance: 24).onEnded { drag in
                let all = DeckTab.allCases
                guard let index = all.firstIndex(of: tab) else { return }
                if drag.translation.width < -40, index + 1 < all.count { select(all[index + 1]) }
                if drag.translation.width > 40, index > 0 { select(all[index - 1]) }
            }
        )
    }

    private func select(_ item: DeckTab) {
        let all = DeckTab.allCases
        forward = (all.firstIndex(of: item) ?? 0) > (all.firstIndex(of: tab) ?? 0)
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { tab = item }
    }

    private func value(for item: DeckTab) -> String {
        switch item {
        case .zoom:
            return LensOption.format(state.displayZoom) + "×"
        case .focus:
            if focusManual { return "MF" }
            return state.aeAfLocked ? "LOCK" : "AF"
        case .exposure:
            if exposureManual { return "ISO \(Int(state.iso.rounded()))" }
            return settings.exposureBias == 0 ? "AUTO" : String(format: "%+.1f", settings.exposureBias)
        case .whiteBalance:
            return settings.whiteBalance == .locked ? "LOCK" : "AUTO"
        case .audio:
            if !state.audioActive { return "OFF" }
            if settings.muted { return "MUTED" }
            let gain = Int(settings.inputGainDB)
            return gain == 0 ? "ON" : (gain > 0 ? "+\(gain) dB" : "\(gain) dB")
        case .assist:
            return activeAssists == 0 ? "OFF" : "\(activeAssists) ON"
        }
    }

    private func highlighted(_ item: DeckTab) -> Bool {
        switch item {
        case .focus: focusManual || state.aeAfLocked
        case .exposure: exposureManual || settings.exposureBias != 0
        case .whiteBalance: settings.whiteBalance == .locked
        case .audio: settings.muted
        case .assist: activeAssists > 0
        case .zoom: false
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .zoom: zoomControls
        case .focus: focusControls
        case .exposure: exposureControls
        case .whiteBalance: whiteBalanceControls
        case .audio: audioControls
        case .assist: assistControls
        }
    }

    private var zoomControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(state.lenses) { lens in
                    DeckChip(title: lens.label + "×", selected: lens == state.activeLens) {
                        camera.selectLens(lens)
                    }
                }
                Spacer()
                DeckChip(title: "Flip", systemImage: "arrow.triangle.2.circlepath", action: camera.flipCamera)
            }
            RulerDial(value: zoomBinding, label: LensOption.format(state.displayZoom) + "×", tickCount: 60)
        }
    }

    private var focusControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                DeckChip(title: "Auto", selected: !focusManual) { camera.setFocusMode(.auto) }
                if state.supportsManualFocus {
                    DeckChip(title: "Manual", selected: focusManual) { camera.setFocusMode(.manual) }
                }
                Spacer()
                if state.aeAfLocked {
                    DeckChip(title: "Unlock", systemImage: "lock.open.fill", action: camera.unlockFocus)
                } else if !focusManual {
                    hint("Tap to focus · hold to lock")
                }
            }
            if state.supportsManualFocus {
                RulerDial(
                    value: lensPositionBinding,
                    label: focusManual ? "\(Int((settings.lensPosition * 100).rounded()))" : "AF",
                    tickCount: 50,
                    leadingIcon: "camera.macro",
                    trailingIcon: "mountain.2",
                    dimmed: !focusManual,
                    onBegin: { if !focusManual { camera.setFocusMode(.manual) } }
                )
            } else {
                hint("This lens doesn't support manual focus.").frame(maxWidth: .infinity, minHeight: 46)
            }
        }
    }

    private var exposureControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                DeckChip(title: "Auto", selected: !exposureManual) { camera.setExposureMode(.auto) }
                if state.supportsManualExposure {
                    DeckChip(title: "ISO \(Int(displayISO.rounded()))", selected: exposureManual && manualDial == .iso) {
                        manualDial = .iso
                        if !exposureManual { camera.setExposureMode(.manual) }
                    }
                    DeckChip(title: Self.shutterLabel(displayShutter), selected: exposureManual && manualDial == .shutter) {
                        manualDial = .shutter
                        if !exposureManual { camera.setExposureMode(.manual) }
                    }
                }
                Spacer()
                if state.aperture > 0 {
                    Text(String(format: "f%.1f", state.aperture))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            if exposureManual {
                if manualDial == .iso {
                    RulerDial(value: logBinding(\.manualISO, range: state.isoRange),
                              label: "ISO \(Int(displayISO.rounded()))", tickCount: 48)
                } else {
                    RulerDial(value: logBinding(\.manualShutter, range: state.shutterRange),
                              label: Self.shutterLabel(displayShutter), tickCount: 48)
                }
            } else {
                RulerDial(value: biasBinding, label: String(format: "%+.1f EV", settings.exposureBias), tickCount: 40)
            }
        }
    }

    private var whiteBalanceControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                wbOption("Auto", systemImage: "a.circle", detail: "Adapts to the light", mode: .auto)
                wbOption("Lock", systemImage: "lock.fill", detail: "Holds the current colour", mode: .locked)
            }
            .fixedSize(horizontal: false, vertical: true)
            .disabled(!state.supportsWhiteBalanceLock)
        }
    }

    private func wbOption(_ title: String, systemImage: String, detail: String, mode: WhiteBalanceMode) -> some View {
        let selected = settings.whiteBalance == mode
        return Button {
            camera.store.settings.whiteBalance = mode
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(selected ? .white.opacity(0.8) : Theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Theme.accent : Theme.pillFill))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
    }

    @ViewBuilder
    private var audioControls: some View {
        if state.audioActive {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    DeckChip(title: settings.muted ? "Muted" : "Mute",
                             systemImage: settings.muted ? "mic.slash.fill" : "mic.fill",
                             selected: settings.muted, action: camera.toggleMute)
                    LevelMeter(
                        level: camera.audioLevels.peaks.max() ?? AudioLevels.floor,
                        hold: camera.audioLevels.holds.max() ?? AudioLevels.floor,
                        axis: .horizontal,
                        segments: 24,
                        dimmed: settings.muted
                    )
                    .frame(height: 10)
                }
                RulerDial(value: gainBinding, label: gainLabel, tickCount: 36)
            }
        } else {
            VStack(spacing: 8) {
                hint(camera.microphoneAuthorization == .authorized
                     ? "Audio is off. OBS receives video only."
                     : "Microphone access is off. Allow it in Settings › Privacy › Microphone.")
                if camera.microphoneAuthorization == .authorized {
                    DeckChip(title: "Turn On Audio", systemImage: "mic.fill") { camera.store.settings.sendAudio = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Preview-only aids. Zebra level and peaking colour live in Settings › Overlays.
    private var assistControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                assistTile("Grid", systemImage: "grid", keyPath: \.gridEnabled)
                assistTile("Level", systemImage: "level", keyPath: \.levelEnabled)
                assistTile("Histogram", systemImage: "chart.bar.xaxis", keyPath: \.histogramEnabled)
                assistTile("Zebra", systemImage: "line.diagonal", keyPath: \.zebraEnabled)
                assistTile("Peaking", systemImage: "scope", keyPath: \.peakingEnabled)
            }
            hint("Overlays show on this screen only, never in OBS.")
        }
    }

    private func assistTile(_ title: String, systemImage: String, keyPath: WritableKeyPath<CaptureSettings, Bool>) -> some View {
        let on = settings[keyPath: keyPath]
        return Button {
            camera.store.settings[keyPath: keyPath].toggle()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 17, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Theme.accent : Theme.pillFill))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var activeAssists: Int {
        [settings.gridEnabled, settings.levelEnabled, settings.histogramEnabled, settings.zebraEnabled, settings.peakingEnabled]
            .filter { $0 }.count
    }

    // MARK: - Bottom row

    private var bottomRow: some View {
        HStack {
            roundButton("moon.fill", label: "Dim screen", action: onDim)
            Spacer()
            StreamButton(state: camera.streamState, action: camera.toggleStreamPaused)
            Spacer()
            roundButton("gearshape.fill", label: "Settings", action: onSettings)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 4)
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Theme.pillFill))
                .rotationEffect(iconRotation)
                .animation(.spring(duration: 0.35), value: iconRotation)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Values & bindings

    private var focusManual: Bool { settings.focusMode == .manual && state.supportsManualFocus }
    private var exposureManual: Bool { settings.exposureMode == .manual && state.supportsManualExposure }

    private var displayISO: Float {
        exposureManual ? min(max(settings.manualISO, state.isoRange.lowerBound), state.isoRange.upperBound) : state.iso
    }

    private var displayShutter: Double {
        exposureManual
            ? min(max(settings.manualShutter, state.shutterRange.lowerBound), state.shutterRange.upperBound)
            : state.exposureDuration
    }

    static func shutterLabel(_ seconds: Double) -> String {
        guard seconds > 0 else { return "–" }
        return seconds >= 1 ? String(format: "%.1fs", seconds) : "1/\(Int((1 / seconds).rounded()))"
    }

    private var gainLabel: String {
        let gain = Int(settings.inputGainDB)
        return gain > 0 ? "+\(gain) dB" : "\(gain) dB"
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
    }

    /// Zoom on a log scale so each lens takes a similar stretch of the ruler.
    private var zoomBinding: Binding<Double> {
        let low = Double(state.minDisplayZoom), high = Double(max(state.maxDisplayZoom, state.minDisplayZoom + 0.01))
        return Binding(
            get: { (log(Double(state.displayZoom)) - log(low)) / (log(high) - log(low)) },
            set: { camera.setZoom(CGFloat(low * pow(high / low, $0))) }
        )
    }

    private var lensPositionBinding: Binding<Double> {
        Binding(
            get: { Double(focusManual ? settings.lensPosition : state.lensPosition) },
            set: { camera.store.settings.lensPosition = Float($0) }
        )
    }

    /// EV in 0.1 steps across the device's bias range (capped at ±2).
    private var biasBinding: Binding<Double> {
        let low = Double(max(-2, state.biasRange.lowerBound)), high = Double(min(2, state.biasRange.upperBound))
        return Binding(
            get: { (Double(settings.exposureBias) - low) / max(high - low, 0.01) },
            set: { camera.store.settings.exposureBias = Float(((low + $0 * (high - low)) * 10).rounded() / 10) }
        )
    }

    /// Input gain, -12…+24 dB in 1 dB steps.
    private var gainBinding: Binding<Double> {
        let range = CaptureSettings.gainRange
        return Binding(
            get: { (settings.inputGainDB - range.lowerBound) / (range.upperBound - range.lowerBound) },
            set: { camera.store.settings.inputGainDB = (range.lowerBound + $0 * (range.upperBound - range.lowerBound)).rounded() }
        )
    }

    /// ISO and shutter on a log scale: each stop takes the same ruler distance.
    private func logBinding<Value: BinaryFloatingPoint>(
        _ keyPath: WritableKeyPath<CaptureSettings, Value>,
        range: ClosedRange<Value>
    ) -> Binding<Double> {
        let low = log(Double(range.lowerBound)), high = log(Double(range.upperBound))
        return Binding(
            get: {
                let value = min(max(camera.store.settings[keyPath: keyPath], range.lowerBound), range.upperBound)
                return high > low ? (log(Double(value)) - low) / (high - low) : 0
            },
            set: { camera.store.settings[keyPath: keyPath] = Value(exp(low + $0 * (high - low))) }
        )
    }
}
