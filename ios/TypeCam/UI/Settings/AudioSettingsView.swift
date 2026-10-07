//
//  AudioSettingsView.swift
//  TypeCam
//

import AVFoundation
import SwiftUI

/// Audio screen (design reference #2): spectrum, level meter, then input and processing options.
struct AudioSettingsView: View {
    @Bindable var camera: CameraModel

    private var store: SettingsStore { camera.store }
    private var route: AudioRouteState { camera.state.audioRoute }

    var body: some View {
        List {
            if store.settings.sendAudio && camera.state.audioActive {
                meterSection
            }

            Section {
                Toggle("Send Audio", isOn: setting(\.sendAudio))
            } footer: {
                if camera.microphoneAuthorization == .denied || camera.microphoneAuthorization == .restricted {
                    Text("Microphone access is off. Turn it on in Settings › Privacy › Microphone.")
                } else if !store.settings.sendAudio {
                    Text("OBS receives video only. Use an OBS audio source instead.")
                }
            }

            if store.settings.sendAudio && camera.state.audioActive {
                inputSection
                processingSection
                formatSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Audio")
        .onAppear { camera.setSpectrumVisible(true) }
        .onDisappear { camera.setSpectrumVisible(false) }
    }

    // MARK: - Sections

    private var meterSection: some View {
        Section {
            SpectrumView(bands: camera.spectrum)
                .frame(height: 70)
                .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 6) {
                Text("Input Level").font(.subheadline)
                ForEach(camera.audioLevels.peaks.indices, id: \.self) { channel in
                    LevelMeter(
                        level: camera.audioLevels.peaks[channel],
                        hold: camera.audioLevels.holds[channel],
                        axis: .horizontal,
                        segments: 32,
                        dimmed: store.settings.muted
                    )
                    .frame(height: 12)
                }
                HStack {
                    ForEach(["-60", "-30", "-12", "-6", "0 dB"], id: \.self) { label in
                        Text(label)
                        if label != "0 dB" { Spacer() }
                    }
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var inputSection: some View {
        Section {
            if !route.inputs.isEmpty {
                OptionPicker(
                    title: "Microphone",
                    options: route.inputs,
                    selection: input,
                    label: \.name,
                    detail: { $0.isBluetooth ? "Bluetooth" : nil }
                )
            }
            if route.positions.count > 1 {
                OptionPicker(
                    title: "Mic Position",
                    options: route.positions,
                    selection: position,
                    label: \.id
                )
            }
            if let patterns = route.currentPosition?.patterns, patterns.count > 1 {
                OptionPicker(
                    title: "Pattern",
                    options: patterns,
                    selection: pattern,
                    label: AudioRouting.patternLabel,
                    detail: AudioRouting.patternDetail
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Input Gain", value: gainLabel)
                Slider(value: setting(\.inputGainDB), in: CaptureSettings.gainRange, step: 1)
            }
            Toggle("Mute", isOn: setting(\.muted))
        } header: {
            Text("Microphone Input")
        } footer: {
            inputFooter
        }
    }

    private var processingSection: some View {
        Section {
            OptionPicker(
                title: "Preset",
                options: AudioPreset.allCases,
                selection: setting(\.audioPreset),
                label: \.label,
                detail: \.detail
            )
            OptionPicker(
                title: "Low Cut Filter",
                options: LowCutFilter.allCases,
                selection: setting(\.lowCut),
                label: \.label,
                footer: "Removes rumble and handling noise below the cutoff."
            )
        } header: {
            Text("Processing")
        }
    }

    private var formatSection: some View {
        Section {
            OptionPicker(
                title: "Format",
                options: AudioFormatSetting.allCases,
                selection: setting(\.audioFormat),
                label: \.label,
                detail: \.detail
            )
            OptionPicker(
                title: "Sample Rate",
                options: CaptureSettings.sampleRates,
                selection: setting(\.sampleRate),
                label: { $0 == 48_000 ? "48 kHz" : "44.1 kHz" }
            )
            if route.inputChannels >= 2 || route.currentPattern == AudioRouting.stereoPattern {
                OptionPicker(
                    title: "Channels",
                    options: [false, true],
                    selection: setting(\.stereo),
                    label: { $0 ? "Stereo" : "Mono" }
                )
            }
        } header: {
            Text("Format")
        }
    }

    @ViewBuilder
    private var inputFooter: some View {
        if route.isBluetooth && !route.isHighQualityBluetooth {
            Text("Bluetooth mics record at call quality on this device. For full quality, use the iPhone mic or a USB mic through a hub.")
        } else if route.isHighQualityBluetooth {
            Text("High-quality Bluetooth recording is on.")
        } else {
            Text("A wired USB-C mic needs a hub, because the cable is carrying the stream.")
        }
    }

    // MARK: - Bindings

    private func setting<Value>(_ keyPath: WritableKeyPath<CaptureSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0 }
        )
    }

    private var input: Binding<AudioInputOption> {
        Binding(
            get: { route.inputs.first { $0.id == route.currentInputID } ?? route.inputs[0] },
            set: { store.settings.audioInputID = $0.id }
        )
    }

    private var position: Binding<MicPositionOption> {
        Binding(
            get: { route.currentPosition ?? route.positions[0] },
            set: { store.settings.micPosition = $0.id }
        )
    }

    /// Choosing the Stereo pattern also switches the stream to stereo, and vice versa.
    private var pattern: Binding<String> {
        Binding(
            get: { route.currentPattern ?? route.currentPosition?.patterns.first ?? "" },
            set: {
                store.settings.polarPattern = $0
                store.settings.stereo = $0 == AudioRouting.stereoPattern
            }
        )
    }

    private var gainLabel: String {
        let gain = Int(store.settings.inputGainDB)
        return gain > 0 ? "+\(gain) dB" : "\(gain) dB"
    }
}
