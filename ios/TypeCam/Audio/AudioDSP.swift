//
//  AudioDSP.swift
//  TypeCam
//
//  Gain → preset (EQ + compressor) → low-cut, per docs/IOS_APP.md.
//

import Foundation

/// RBJ cookbook biquad, transposed direct form II, with state per channel.
nonisolated struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: [Float] = [0, 0]
    private var z2: [Float] = [0, 0]

    static func highPass(_ frequency: Float, sampleRate: Float, q: Float = 0.707) -> Biquad {
        let (cosw, alpha) = terms(frequency, sampleRate, q)
        return Biquad(b0: (1 + cosw) / 2, b1: -(1 + cosw), b2: (1 + cosw) / 2,
                      a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
    }

    static func peak(_ frequency: Float, gainDB: Float, sampleRate: Float, q: Float = 1) -> Biquad {
        let (cosw, alpha) = terms(frequency, sampleRate, q)
        let a = pow(10, gainDB / 40)
        return Biquad(b0: 1 + alpha * a, b1: -2 * cosw, b2: 1 - alpha * a,
                      a0: 1 + alpha / a, a1: -2 * cosw, a2: 1 - alpha / a)
    }

    static func lowShelf(_ frequency: Float, gainDB: Float, sampleRate: Float) -> Biquad {
        let (cosw, _) = terms(frequency, sampleRate, 0.707)
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Float.pi * frequency / sampleRate
        let alpha = sin(w0) / 2 * sqrt(2)
        let k = 2 * sqrt(a) * alpha
        return Biquad(b0: a * ((a + 1) - (a - 1) * cosw + k),
                      b1: 2 * a * ((a - 1) - (a + 1) * cosw),
                      b2: a * ((a + 1) - (a - 1) * cosw - k),
                      a0: (a + 1) + (a - 1) * cosw + k,
                      a1: -2 * ((a - 1) + (a + 1) * cosw),
                      a2: (a + 1) + (a - 1) * cosw - k)
    }

    private static func terms(_ frequency: Float, _ sampleRate: Float, _ q: Float) -> (Float, Float) {
        let w0 = 2 * Float.pi * frequency / sampleRate
        return (cos(w0), sin(w0) / (2 * q))
    }

    private init(b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    mutating func process(_ samples: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        var s1 = z1[channel], s2 = z2[channel]
        for i in 0..<count {
            let x = samples[i]
            let y = b0 * x + s1
            s1 = b1 * x - a1 * y + s2
            s2 = b2 * x - a2 * y
            samples[i] = y
        }
        z1[channel] = s1
        z2[channel] = s2
    }
}

/// Feed-forward peak compressor, linked across channels.
nonisolated struct Compressor {
    let thresholdDB: Float
    let ratio: Float
    let makeupDB: Float
    private let attack: Float
    private let release: Float
    private var envelope: Float = 0

    init(thresholdDB: Float, ratio: Float, makeupDB: Float, sampleRate: Float) {
        self.thresholdDB = thresholdDB
        self.ratio = ratio
        self.makeupDB = makeupDB
        attack = exp(-1 / (0.005 * sampleRate))
        release = exp(-1 / (0.1 * sampleRate))
    }

    mutating func process(_ channels: [UnsafeMutablePointer<Float>], count: Int) {
        let slope = 1 - 1 / ratio
        for i in 0..<count {
            var level: Float = 0
            for channel in channels { level = max(level, abs(channel[i])) }
            let coefficient = level > envelope ? attack : release
            envelope = coefficient * envelope + (1 - coefficient) * level
            let over = 20 * log10(envelope + 1e-9) - thresholdDB
            let gain = pow(10, ((over > 0 ? -over * slope : 0) + makeupDB) / 20)
            for channel in channels { channel[i] *= gain }
        }
    }
}

nonisolated struct DSPSettings: Equatable, Sendable {
    var gainDB: Float = 0
    var muted = false
    var preset: AudioPreset = .natural
    var lowCut: LowCutFilter = .off
}

nonisolated struct AudioDSP {
    private(set) var settings = DSPSettings()
    private var sampleRate: Float = 0
    private var presetFilters: [Biquad] = []
    private var compressor: Compressor?
    private var lowCut: Biquad?

    mutating func configure(_ settings: DSPSettings, sampleRate: Float) {
        guard settings != self.settings || sampleRate != self.sampleRate else { return }
        let rebuild = settings.preset != self.settings.preset || settings.lowCut != self.settings.lowCut
            || sampleRate != self.sampleRate
        self.settings = settings
        self.sampleRate = sampleRate
        guard rebuild else { return }

        switch settings.preset {
        case .natural:
            presetFilters = []
            compressor = nil
        case .voiceBoost:
            presetFilters = [.highPass(100, sampleRate: sampleRate), .peak(3000, gainDB: 3, sampleRate: sampleRate)]
            compressor = Compressor(thresholdDB: -18, ratio: 3, makeupDB: 4, sampleRate: sampleRate)
        case .outdoor:
            presetFilters = [.highPass(150, sampleRate: sampleRate), .lowShelf(250, gainDB: -4, sampleRate: sampleRate)]
            compressor = Compressor(thresholdDB: -18, ratio: 2, makeupDB: 2, sampleRate: sampleRate)
        case .music:
            presetFilters = []
            compressor = Compressor(thresholdDB: -12, ratio: 1.5, makeupDB: 1, sampleRate: sampleRate)
        }
        lowCut = settings.lowCut.frequency.map { .highPass($0, sampleRate: sampleRate) }
    }

    mutating func process(_ channels: [UnsafeMutablePointer<Float>], count: Int) {
        if settings.muted {
            for channel in channels { channel.update(repeating: 0, count: count) }
            return
        }
        if settings.gainDB != 0 {
            let gain = pow(10, settings.gainDB / 20)
            for channel in channels {
                for i in 0..<count { channel[i] *= gain }
            }
        }
        for index in presetFilters.indices {
            for (c, channel) in channels.enumerated() { presetFilters[index].process(channel, count: count, channel: c) }
        }
        compressor?.process(channels, count: count)
        if lowCut != nil {
            for (c, channel) in channels.enumerated() { lowCut!.process(channel, count: count, channel: c) }
        }
        // Hard clip after makeup gain so the encoder never wraps.
        for channel in channels {
            for i in 0..<count { channel[i] = min(1, max(-1, channel[i])) }
        }
    }
}
