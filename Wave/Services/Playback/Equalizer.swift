import AVFoundation
import Foundation

// MARK: - 15-band parametric equalizer
//
// Band centres follow the ISO 1/3-octave-ish ladder used by the Android app's
// parametric EQ (25 Hz – 16 kHz). Gains are in dB and clamped to +/-12 dB;
// the preamp is a separate global attenuation, also in dB.

struct EQSettings: Sendable, Codable, Hashable {
    /// Centre frequencies of the 15 bands, in Hz.
    static let bandFrequencies: [Double] = [
        25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000,
    ]

    static let bandCount = 15

    /// Hard limit for any single band gain, in dB.
    static let maxGainDb: Double = 12

    /// Per-band gains in dB, one per entry in `bandFrequencies`.
    var gains: [Double]

    /// Global preamp in dB (negative values leave headroom for boosts).
    var preamp: Double

    init(gains: [Double], preamp: Double = 0) {
        var padded = gains
        if padded.count < Self.bandCount {
            padded += Array(repeating: 0, count: Self.bandCount - padded.count)
        }
        self.gains = Array(padded.prefix(Self.bandCount)).map {
            $0.clamped(to: -Self.maxGainDb...Self.maxGainDb)
        }
        self.preamp = preamp.clamped(to: -24...Self.maxGainDb)
    }

    static let flat = EQSettings(gains: Array(repeating: 0, count: bandCount))

    // Conventional named presets, the same curves music players ship as
    // Rock / Pop / Jazz / Classical / Bass / Treble / Vocal. These are
    // hand-authored starting points, not measurements.
    static let rock = EQSettings(gains: [4, 3, 2, 0, -1, -1, 0, 1, 2, 3, 4, 4, 3, 2, 2])
    static let pop = EQSettings(gains: [2, 1, 0, -1, -1, 0, 1, 2, 2, 2, 1, 0, 0, 1, 2])
    static let jazz = EQSettings(gains: [3, 2, 1, 0, 0, 1, 1, 2, 2, 2, 1, 1, 2, 2, 3])
    static let classical = EQSettings(gains: [3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4])
    static let bass = EQSettings(gains: [6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, -1])
    static let treble = EQSettings(gains: [-1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6])
    static let vocal = EQSettings(gains: [-2, -1, 0, 1, 2, 2, 2, 3, 3, 2, 1, 0, 0, 1, 1])

    static let namedPresets: [(name: String, settings: EQSettings)] = [
        ("Flat", .flat),
        ("Rock", .rock),
        ("Pop", .pop),
        ("Jazz", .jazz),
        ("Classical", .classical),
        ("Bass", .bass),
        ("Treble", .treble),
        ("Vocal", .vocal),
    ]

    /// Builds an `AVAudioUnitEQ` with 15 bands wired to these gains and
    /// attaches it to the engine. Returns the node so the caller can connect
    /// it into the graph. Band 0 is a low shelf, band 14 a high shelf, the
    /// rest are parametric peaking filters with a 1-octave bandwidth.
    func apply(to engine: AVAudioEngine) -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: Self.bandCount)
        apply(to: eq)
        engine.attach(eq)
        return eq
    }

    /// Writes these gains into an already-attached `AVAudioUnitEQ`. Safe to
    /// call while audio is playing: band gains update live.
    func apply(to eqNode: AVAudioUnitEQ) {
        for index in 0..<Self.bandCount {
            guard index < eqNode.bands.count else { continue }
            let band = eqNode.bands[index]
            band.frequency = Float(Self.bandFrequencies[index])
            band.gain = Float(gains[index])
            band.bandwidth = 1.0
            band.bypass = false
            switch index {
            case 0: band.filterType = .lowShelf
            case Self.bandCount - 1: band.filterType = .highShelf
            default: band.filterType = .parametric
            }
        }
    }
}

// MARK: - AutoEQ

/// One biquad filter from an AutoEq ParametricEQ profile (jaakkopasanen/AutoEq).
/// `type` is one of `PK` (peaking), `LSC` (low shelf) or `HSC` (high shelf).
struct AutoEQFilter: Sendable, Codable, Hashable {
    var type: String
    var frequencyHz: Double
    var gainDb: Double
    var q: Double

    enum CodingKeys: String, CodingKey {
        case type
        case frequencyHz
        case gainDb
        case q
    }
}

enum AutoEQFormFactor: String, Sendable, Codable {
    case overEar = "over-ear"
    case inEar = "in-ear"
}

/// One headphone AutoEq profile: 10 parametric filters plus a preamp, taken
/// verbatim from the AutoEq database (`results/<source>/<form>/<name>/
/// <name> ParametricEQ.txt`, jaakkopasanen/AutoEq, MIT). `bandGains` is the
/// profile evaluated at the 15 EQ band frequencies (see
/// `AutoEQLibrary.eqSettings(for:)`).
struct AutoEQPreset: Sendable, Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var source: String
    var formFactor: AutoEQFormFactor
    var preampDb: Double
    var filters: [AutoEQFilter]

    enum CodingKeys: String, CodingKey {
        case name
        case source
        case formFactor
        case preampDb
        case filters
    }
}

/// One AutoEq target curve (Harman, oratory1990 optimum, diffuse field…),
/// copied verbatim from the Android app's bundled `assets/autoeq_targets.json`.
/// `deltaOverEar` / `deltaInEar` are the curve's deviation from flat in dB,
/// sampled at the 121 frequencies in the file's `frequencies` array.
struct AutoEQTarget: Sendable, Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var family: String
    var deltaOverEar: [Double]
    var deltaInEar: [Double]
}

/// The bundled AutoEq data: `Wave/Resources/autoeq_presets.json`. Same top
/// level shape as the Android asset (`frequencies` + `targets`), plus a
/// `headphones` array of real per-headphone ParametricEQ profiles fetched
/// from the AutoEq database. Headphone measurements are per-model; a profile
/// only corrects the named model, measured by the named source.
struct AutoEQLibrary: Sendable {
    var frequencies: [Double]
    var targets: [AutoEQTarget]
    var presets: [AutoEQPreset]

    /// Loads the bundled JSON. Returns `nil` when the file is missing or
    /// unreadable — the app then offers only the hand-authored presets.
    static func load(bundle: Bundle = .main) -> AutoEQLibrary? {
        guard let url = bundle.url(forResource: "autoeq_presets", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return load(data: data)
    }

    static func load(data: Data) -> AutoEQLibrary? {
        struct File: Decodable {
            var frequencies: [Double]
            var targets: [AutoEQTarget]
            var headphones: [AutoEQPreset]
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return AutoEQLibrary(frequencies: file.frequencies, targets: file.targets, presets: file.headphones)
    }

    func preset(named name: String) -> AutoEQPreset? {
        presets.first { $0.name == name }
    }

    /// Converts a headphone profile into 15-band EQ settings by evaluating
    /// the summed biquad response of its filters at each band frequency
    /// (RBJ cookbook coefficients, evaluated at a 48 kHz reference rate —
    /// the response shape is what matters, not the exact sample rate).
    /// The preamp becomes the settings' preamp.
    func eqSettings(for preset: AutoEQPreset) -> EQSettings {
        let gains = EQSettings.bandFrequencies.map { frequency in
            preset.filters
                .map { $0.responseDb(at: frequency) }
                .reduce(0, +)
                .clamped(to: -EQSettings.maxGainDb...EQSettings.maxGainDb)
        }
        return EQSettings(gains: gains, preamp: preset.preampDb)
    }

    /// Converts a target curve into 15-band EQ settings by sampling the
    /// curve's delta (log-interpolated between the file's frequency points)
    /// at each band frequency. `overEar` picks the over-ear or in-ear delta.
    func eqSettings(forTarget target: AutoEQTarget, overEar: Bool) -> EQSettings {
        let delta = overEar ? target.deltaOverEar : target.deltaInEar
        guard delta.count == frequencies.count, !frequencies.isEmpty else {
            return .flat
        }
        let gains = EQSettings.bandFrequencies.map { frequency in
            sampleDelta(delta, at: frequency)
                .clamped(to: -EQSettings.maxGainDb...EQSettings.maxGainDb)
        }
        return EQSettings(gains: gains)
    }

    /// Log-frequency interpolation of a delta curve at one frequency.
    func sampleDelta(_ delta: [Double], at frequency: Double) -> Double {
        let freqs = frequencies
        if frequency <= freqs.first! { return delta.first! }
        if frequency >= freqs.last! { return delta.last! }
        var low = 0
        var high = freqs.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if freqs[mid] <= frequency { low = mid } else { high = mid }
        }
        let f0 = freqs[low]
        let f1 = freqs[high]
        let t = (log(frequency) - log(f0)) / (log(f1) - log(f0))
        return delta[low] + (delta[high] - delta[low]) * t
    }
}

extension AutoEQFilter {
    /// Magnitude response of this biquad in dB at `frequency` Hz, using the
    /// RBJ Audio EQ Cookbook coefficients. The coefficients are built from
    /// this filter's own centre frequency (`frequencyHz`); the magnitude is
    /// then evaluated at the requested `frequency`. `LSC`/`HSC` use a shelf
    /// slope of S = 1, `PK` is a peaking filter. Evaluated at 48 kHz.
    func responseDb(at frequency: Double, sampleRate: Double = 48_000) -> Double {
        // Coefficients from the filter's centre frequency.
        let wc = 2 * Double.pi * frequencyHz / sampleRate
        let cosWc = cos(wc)
        let sinWc = sin(wc)
        let a: Double
        let b0: Double
        let b1: Double
        let b2: Double
        let a0: Double
        let a1: Double
        let a2: Double
        switch type {
        case "LSC": // low shelf, S = 1
            a = pow(10, gainDb / 40)
            let sqrtA = sqrt(a)
            let shelfAlpha = sinWc / 2 * sqrt(pow(log(2) / 2, 2) + 1)
            b0 = a * ((a + 1) - (a - 1) * cosWc + 2 * sqrtA * shelfAlpha)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosWc)
            b2 = a * ((a + 1) - (a - 1) * cosWc - 2 * sqrtA * shelfAlpha)
            a0 = (a + 1) + (a - 1) * cosWc + 2 * sqrtA * shelfAlpha
            a1 = -2 * ((a - 1) + (a + 1) * cosWc)
            a2 = (a + 1) + (a - 1) * cosWc - 2 * sqrtA * shelfAlpha
        case "HSC": // high shelf, S = 1
            a = pow(10, gainDb / 40)
            let sqrtA = sqrt(a)
            let shelfAlpha = sinWc / 2 * sqrt(pow(log(2) / 2, 2) + 1)
            b0 = a * ((a + 1) + (a - 1) * cosWc + 2 * sqrtA * shelfAlpha)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosWc)
            b2 = a * ((a + 1) + (a - 1) * cosWc - 2 * sqrtA * shelfAlpha)
            a0 = (a + 1) - (a - 1) * cosWc + 2 * sqrtA * shelfAlpha
            a1 = 2 * ((a - 1) - (a + 1) * cosWc)
            a2 = (a + 1) - (a - 1) * cosWc - 2 * sqrtA * shelfAlpha
        default: // "PK": peaking
            a = pow(10, gainDb / 40)
            let alpha = sinWc / (2 * q)
            b0 = 1 + alpha * a
            b1 = -2 * cosWc
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosWc
            a2 = 1 - alpha / a
        }
        // |H(e^jw)|^2 at the requested evaluation frequency.
        let w = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w)
        let cos2W = cos(2 * w)
        let num = b0 * b0 + b1 * b1 + b2 * b2 + 2 * (b0 * b1 + b1 * b2) * cosW + 2 * b0 * b2 * cos2W
        let den = a0 * a0 + a1 * a1 + a2 * a2 + 2 * (a0 * a1 + a1 * a2) * cosW + 2 * a0 * a2 * cos2W
        guard den > 0, num > 0 else { return 0 }
        return 10 * log10(num / den)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
