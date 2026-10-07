//
//  SettingsView.swift
//  TypeCam
//

import SwiftUI

/// Settings sheet (docs/IOS_APP.md). Only values the active device supports are offered.
/// Audio and Overlays sections arrive with M4 and M6.
struct SettingsView: View {
    @Bindable var camera: CameraModel
    @Environment(\.dismiss) private var dismiss

    private var store: SettingsStore { camera.store }
    private var state: CameraState { camera.state }

    var body: some View {
        NavigationStack {
            List {
                videoSection
                lensSection
                displaySection
                Section {
                    NavigationLink("Connection & About") { AboutView() }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    // MARK: - Video

    private var videoSection: some View {
        Section("Video") {
            if !state.availableResolutions.isEmpty {
                OptionPicker(
                    title: "Resolution",
                    options: state.availableResolutions,
                    selection: resolution,
                    label: \.label,
                    detail: { "\($0.width) × \($0.height)" },
                    footer: "Only resolutions this camera supports are shown."
                )
            }
            if !state.availableFrameRates.isEmpty {
                OptionPicker(
                    title: "Frame Rate",
                    options: state.availableFrameRates,
                    selection: frameRate,
                    label: { "\($0) fps" },
                    footer: "Only frame rates this camera supports at the current resolution are shown."
                )
            }
            OptionPicker(
                title: "Codec",
                options: VideoCodec.allCases,
                selection: setting(\.codec),
                label: \.label,
                detail: { $0 == .hevc ? "H.265 · Better quality per bit" : "AVC · Most compatible" }
            )

            Toggle("Auto Bitrate", isOn: setting(\.bitrateAuto))
            if store.settings.bitrateAuto {
                LabeledContent("Bitrate", value: "\(Int(autoBitrate)) Mbps")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Bitrate", value: "\(Int(store.settings.bitrateMbps)) Mbps")
                    Slider(value: setting(\.bitrateMbps), in: CaptureSettings.bitrateRange, step: 1)
                }
            }

            OptionPicker(
                title: "Keyframe Interval",
                options: CaptureSettings.keyframeIntervals,
                selection: setting(\.keyframeInterval),
                label: { $0 == 0.5 ? "0.5 s" : "\(Int($0)) s" },
                footer: "Shorter intervals let OBS recover faster after a glitch but use more bitrate."
            )
            OptionPicker(
                title: "Orientation",
                options: OrientationLock.allCases,
                selection: setting(\.orientation),
                label: \.label,
                detail: {
                    switch $0 {
                    case .auto: "Follows how you hold the phone"
                    case .landscape: "Always sends a landscape frame"
                    case .portrait: "Always sends a portrait frame"
                    }
                }
            )
            Toggle("Mirror Front Camera", isOn: setting(\.mirrorFront))
        }
    }

    // MARK: - Lens & Image

    private var lensSection: some View {
        Section {
            if state.lenses.count > 1, let active = state.activeLens {
                OptionPicker(title: "Lens", options: state.lenses, selection: lens(active), label: { $0.label + "×" })
            }
            if state.supportsStabilization {
                Toggle("Stabilization", isOn: stabilization)
            }
            if state.hasTorch {
                Toggle("Torch", isOn: setting(\.torchOn))
                if store.settings.torchOn {
                    Slider(value: setting(\.torchLevel), in: 0.05...1) {
                        Text("Torch Level")
                    } minimumValueLabel: {
                        Image(systemName: "flashlight.off.fill")
                    } maximumValueLabel: {
                        Image(systemName: "flashlight.on.fill")
                    }
                }
            }
        } header: {
            Text("Lens & Image")
        } footer: {
            if state.supportsStabilization {
                Text("Standard stabilization adds a little latency. Cinematic modes aren't offered.")
            }
        }
    }

    // MARK: - Display & Power

    private var displaySection: some View {
        Section {
            OptionPicker(
                title: "Dim Style",
                options: DimStyle.allCases,
                selection: setting(\.dimStyle),
                label: \.label,
                detail: { $0 == .blackout ? "Black screen, lowest power" : "Darkened preview at minimum brightness" }
            )
        } header: {
            Text("Display & Power")
        } footer: {
            Text("The screen never auto-locks while TypeCam is open; iOS stops the camera when the phone locks.")
        }
    }

    // MARK: - Bindings

    private func setting<Value>(_ keyPath: WritableKeyPath<CaptureSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0 }
        )
    }

    /// Shows the clamped (active) value but writes the user's preference.
    private var resolution: Binding<VideoResolution> {
        Binding(
            get: { state.activeResolution ?? store.settings.resolution },
            set: { store.settings.resolution = $0 }
        )
    }

    private var frameRate: Binding<Int> {
        Binding(
            get: { state.activeFrameRate },
            set: { store.settings.frameRate = $0 }
        )
    }

    private var stabilization: Binding<Bool> {
        Binding(
            get: { store.settings.stabilization == .standard },
            set: { store.settings.stabilization = $0 ? .standard : .off }
        )
    }

    private func lens(_ active: LensOption) -> Binding<LensOption> {
        Binding(get: { active }, set: { camera.selectLens($0) })
    }

    private var autoBitrate: Double {
        store.settings.autoBitrateMbps(
            resolution: state.activeResolution ?? store.settings.resolution,
            frameRate: state.activeFrameRate
        )
    }
}
