import AVFoundation
import XCTest

@testable import Wave

// MARK: - Equalizer tests
//
// No network: the AutoEQ data under test is an inline JSON string in the
// same shape as Wave/Resources/autoeq_presets.json. The bundled file itself
// is validated by scripts/verify.py's JSON check; the loader logic is
// proven here.

final class EqualizerTests: XCTestCase {
    func testBandCountIs15() {
        XCTAssertEqual(EQSettings.bandCount, 15)
        XCTAssertEqual(EQSettings.bandFrequencies.count, 15)
        XCTAssertEqual(EQSettings.flat.gains.count, 15)
        XCTAssertEqual(EQSettings.bandFrequencies.first, 25)
        XCTAssertEqual(EQSettings.bandFrequencies.last, 16000)
    }

    func testNamedPresetGainsInRange() {
        for (name, preset) in EQSettings.namedPresets {
            XCTAssertEqual(preset.gains.count, 15, "\(name) must have 15 gains")
            for gain in preset.gains {
                XCTAssertGreaterThanOrEqual(gain, -EQSettings.maxGainDb, "\(name) gain below range")
                XCTAssertLessThanOrEqual(gain, EQSettings.maxGainDb, "\(name) gain above range")
            }
        }
        XCTAssertTrue(EQSettings.flat.gains.allSatisfy { $0 == 0 })
    }

    func testGainsAreClamped() {
        let settings = EQSettings(gains: [100, -100, 5], preamp: 99)
        XCTAssertEqual(settings.gains[0], EQSettings.maxGainDb)
        XCTAssertEqual(settings.gains[1], -EQSettings.maxGainDb)
        XCTAssertEqual(settings.gains[2], 5)
        XCTAssertEqual(settings.gains.count, 15)
        XCTAssertEqual(settings.preamp, EQSettings.maxGainDb)
    }

    func testShortGainsArePadded() {
        let settings = EQSettings(gains: [3, -2])
        XCTAssertEqual(settings.gains.count, 15)
        XCTAssertEqual(settings.gains[0], 3)
        XCTAssertEqual(settings.gains[1], -2)
        XCTAssertEqual(settings.gains[2], 0)
    }

    func testApplyToEQNode() {
        let node = AVAudioUnitEQ(numberOfBands: EQSettings.bandCount)
        EQSettings.rock.apply(to: node)
        XCTAssertEqual(node.bands.count, 15)
        XCTAssertEqual(node.bands[0].filterType, .lowShelf)
        XCTAssertEqual(node.bands[14].filterType, .highShelf)
        XCTAssertEqual(node.bands[1].filterType, .parametric)
        XCTAssertEqual(node.bands[0].gain, Float(EQSettings.rock.gains[0]))
        XCTAssertEqual(node.bands[0].frequency, 25)
        XCTAssertEqual(node.bands[8].frequency, 1000)
        XCTAssertEqual(node.bands[14].frequency, 16000)
        XCTAssertFalse(node.bands[0].bypass)
    }

    func testPeakingFilterResponse() {
        // A +6 dB peaking filter at 1 kHz, Q 1: the response at its centre
        // is the full +6 dB, and far away it is ~0 dB.
        let filter = AutoEQFilter(type: "PK", frequencyHz: 1000, gainDb: 6, q: 1.0)
        XCTAssertEqual(filter.responseDb(at: 1000), 6, accuracy: 0.01)
        XCTAssertEqual(filter.responseDb(at: 25), 0, accuracy: 0.1)
        XCTAssertEqual(filter.responseDb(at: 16000), 0, accuracy: 0.1)
        // Half an octave off-centre the response is between 0 and +6.
        let halfOctave = filter.responseDb(at: 1414)
        XCTAssertGreaterThan(halfOctave, 1)
        XCTAssertLessThan(halfOctave, 6)
    }

    func testLowShelfResponse() {
        let filter = AutoEQFilter(type: "LSC", frequencyHz: 105, gainDb: -3.2, q: 0.7)
        // Well below the shelf corner the full cut applies; well above it
        // the response returns to ~0 dB.
        XCTAssertEqual(filter.responseDb(at: 25), -3.2, accuracy: 0.15)
        XCTAssertEqual(filter.responseDb(at: 16000), 0, accuracy: 0.1)
    }

    func testAutoEQLibraryLoadsFromInlineJSON() throws {
        let json = """
        {
          "frequencies": [20, 100, 1000, 10000, 20000],
          "targets": [
            {
              "id": "flat",
              "name": "Flat",
              "family": "flat",
              "deltaOverEar": [0, 0, 0, 0, 0],
              "deltaInEar": [0, 0, 0, 0, 0]
            },
            {
              "id": "harman_oe_2018",
              "name": "Harman over-ear 2018",
              "family": "over",
              "deltaOverEar": [-4, -2, 0, 2, -6],
              "deltaInEar": [-4, -2, 0, 2, -6]
            }
          ],
          "headphones": [
            {
              "name": "Test Headphones",
              "source": "oratory1990",
              "formFactor": "over-ear",
              "preampDb": -6.2,
              "filters": [
                {"type": "PK", "frequencyHz": 1000, "gainDb": 6, "q": 1.0},
                {"type": "LSC", "frequencyHz": 105, "gainDb": -3.2, "q": 0.7}
              ]
            }
          ]
        }
        """
        let library = try XCTUnwrap(AutoEQLibrary.load(data: Data(json.utf8)))
        XCTAssertEqual(library.targets.count, 2)
        XCTAssertEqual(library.presets.count, 1)

        let preset = try XCTUnwrap(library.preset(named: "Test Headphones"))
        XCTAssertEqual(preset.filters.count, 2)
        XCTAssertEqual(preset.preampDb, -6.2)
        XCTAssertNil(library.preset(named: "No Such Headphones"))

        let settings = library.eqSettings(for: preset)
        XCTAssertEqual(settings.gains.count, 15)
        XCTAssertEqual(settings.preamp, -6.2)
        for gain in settings.gains {
            XCTAssertGreaterThanOrEqual(gain, -EQSettings.maxGainDb)
            XCTAssertLessThanOrEqual(gain, EQSettings.maxGainDb)
        }
        // The 1 kHz band (index 8) carries most of the +6 dB peak.
        XCTAssertGreaterThan(settings.gains[8], 4)
        // The 25 Hz band (index 0) carries the low-shelf cut.
        XCTAssertLessThan(settings.gains[0], 0)
    }

    func testTargetCurveSampling() throws {
        let json = """
        {
          "frequencies": [20, 1000, 20000],
          "targets": [
            {
              "id": "peak",
              "name": "Peak",
              "family": "over",
              "deltaOverEar": [0, 6, 0],
              "deltaInEar": [0, 6, 0]
            }
          ],
          "headphones": []
        }
        """
        let library = try XCTUnwrap(AutoEQLibrary.load(data: Data(json.utf8)))
        let target = try XCTUnwrap(library.targets.first)
        let settings = library.eqSettings(forTarget: target, overEar: true)
        XCTAssertEqual(settings.gains.count, 15)
        // Sampled exactly at 1 kHz (band index 8) the delta is +6.
        XCTAssertEqual(settings.gains[8], 6, accuracy: 0.001)
        // At the ends of the curve the delta is 0.
        XCTAssertEqual(settings.gains[0], 0, accuracy: 0.001)
        XCTAssertEqual(settings.gains[14], 0, accuracy: 0.001)
    }

    func testBundledAutoEQFileLoads() {
        // The real bundled file ships with the app target; the unit-test
        // bundle can see it through the main bundle in an app-hosted test.
        let library = AutoEQLibrary.load()
        XCTAssertNotNil(library, "autoeq_presets.json must load from the app bundle")
        XCTAssertEqual(library?.presets.count, 20)
        XCTAssertEqual(library?.targets.count, 15)
        let xm5 = library?.preset(named: "Sony WH-1000XM5")
        XCTAssertNotNil(xm5)
        XCTAssertEqual(xm5?.filters.count, 10)
        if let xm5, let library {
            let settings = library.eqSettings(for: xm5)
            XCTAssertEqual(settings.gains.count, 15)
            XCTAssertEqual(settings.preamp, -6.2, accuracy: 0.001)
        }
    }

    func testLoudnessGain() {
        let track = Track(id: "x", title: "Test")
        // No measured loudness: no adjustment, never a fake value.
        XCTAssertEqual(gainAdjustment(for: track, measuredLoudness: nil), 0)
        // Measured at -20 LUFS: +6 dB to reach the -14 LUFS target.
        XCTAssertEqual(gainAdjustment(for: track, measuredLoudness: -20), 6)
        // Measured at -8 LUFS: -6 dB.
        XCTAssertEqual(gainAdjustment(for: track, measuredLoudness: -8), -6)
        // Clamped to +/-12 dB.
        XCTAssertEqual(gainAdjustment(for: track, measuredLoudness: -40), 12)
        XCTAssertEqual(gainAdjustment(for: track, measuredLoudness: 10), -12)
        XCTAssertEqual(linearGain(fromDb: 0), 1, accuracy: 0.001)
        XCTAssertEqual(linearGain(fromDb: -6), 0.501, accuracy: 0.01)
    }
}
