//
//  AudioRouting.swift
//  TypeCam
//

import AVFoundation

nonisolated struct AudioInputOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isBluetooth: Bool
}

/// A built-in mic position (data source) and the polar patterns it supports.
nonisolated struct MicPositionOption: Identifiable, Hashable, Sendable {
    let id: String
    let patterns: [String]
}

nonisolated struct AudioRouteState: Equatable, Sendable {
    var inputs: [AudioInputOption] = []
    var currentInputID: String?
    /// Positions of the built-in mic. Empty when another input is active.
    var positions: [MicPositionOption] = []
    var currentPositionID: String?
    var currentPattern: String?
    var isBluetooth = false
    var isHighQualityBluetooth = false
    var inputChannels = 1

    var currentPosition: MicPositionOption? {
        positions.first { $0.id == currentPositionID }
    }
}

/// Applies the audio settings to `AVAudioSession` and reads back what the system actually chose.
/// Call off the main thread: session calls can block.
nonisolated enum AudioRouting {
    static func configure(_ settings: CaptureSettings) -> AudioRouteState {
        let session = AVAudioSession.sharedInstance()

        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .mixWithOthers]
        if #available(iOS 26.0, *) {
            // Full-bandwidth recording on supporting AirPods; HFP remains the fallback.
            options.insert(.bluetoothHighQualityRecording)
        }
        try? session.setCategory(.playAndRecord, mode: .default, options: options)
        try? session.setPreferredSampleRate(Double(settings.sampleRate))
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)

        let inputs = session.availableInputs ?? []
        let builtIn = inputs.first { $0.portType == .builtInMic }
        let preferred = inputs.first { $0.uid == settings.audioInputID } ?? builtIn
        if let preferred {
            try? session.setPreferredInput(preferred)
        }

        if let port = preferred, port.portType == .builtInMic, let sources = port.dataSources, !sources.isEmpty {
            let source = sources.first { $0.dataSourceName == settings.micPosition }
                ?? sources.first { $0.orientation == .bottom }
                ?? sources[0]
            let supported = source.supportedPolarPatterns ?? []
            let pattern = supported.first { $0.rawValue == settings.polarPattern }
                ?? supported.first { $0 == .omnidirectional }
            if let pattern {
                try? source.setPreferredPolarPattern(pattern)
                if pattern == .stereo {
                    // Required for stereo so left/right map correctly; the stream is landscape by default.
                    try? session.setPreferredInputOrientation(.landscapeLeft)
                }
            }
            try? port.setPreferredDataSource(source)
        }

        if settings.stereo {
            try? session.setPreferredInputNumberOfChannels(min(2, session.maximumInputNumberOfChannels))
        }
        return currentState()
    }

    static func currentState() -> AudioRouteState {
        let session = AVAudioSession.sharedInstance()
        var state = AudioRouteState()
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE, .bluetoothA2DP]

        let inputs = session.availableInputs ?? []
        state.inputs = inputs.map {
            AudioInputOption(
                id: $0.uid,
                name: $0.portType == .builtInMic ? "iPhone Microphone" : $0.portName,
                isBluetooth: bluetooth.contains($0.portType)
            )
        }

        let current = session.currentRoute.inputs.first
        state.currentInputID = current?.uid
        state.isBluetooth = current.map { bluetooth.contains($0.portType) } ?? false
        if #available(iOS 26.0, *), let current {
            state.isHighQualityBluetooth = current.bluetoothMicrophoneExtension?.highQualityRecording.isEnabled ?? false
        }
        state.inputChannels = max(1, session.inputNumberOfChannels)

        if let builtIn = inputs.first(where: { $0.portType == .builtInMic }), current?.portType == .builtInMic {
            state.positions = (builtIn.dataSources ?? []).map {
                MicPositionOption(id: $0.dataSourceName, patterns: ($0.supportedPolarPatterns ?? []).map(\.rawValue))
            }
            let selected = builtIn.selectedDataSource ?? builtIn.preferredDataSource
            state.currentPositionID = selected?.dataSourceName
            state.currentPattern = selected?.selectedPolarPattern?.rawValue
        }
        return state
    }

    static let stereoPattern = AVAudioSession.PolarPattern.stereo.rawValue

    static func patternDetail(_ raw: String) -> String? {
        switch AVAudioSession.PolarPattern(rawValue: raw) {
        case .omnidirectional: "Picks up sound from all directions"
        case .cardioid: "Focuses on sound in front of the mic"
        case .subcardioid: "Mostly front, some sides"
        case .stereo: "Left/right image (sends stereo)"
        default: nil
        }
    }

    static func patternLabel(_ raw: String) -> String {
        switch AVAudioSession.PolarPattern(rawValue: raw) {
        case .omnidirectional: "Omni"
        case .cardioid: "Cardioid"
        case .subcardioid: "Subcardioid"
        case .stereo: "Stereo"
        default: raw
        }
    }
}
