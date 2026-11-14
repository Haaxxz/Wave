import Foundation

// MARK: - Loudness normalisation
//
// Target: -14 LUFS, the level streaming services normalise to. The gain for
// a track is `target - measured`, clamped so a single track never jumps more
// than +/-12 dB.
//
// Honest limit: Wave has no measured loudness for a track. `Track` carries
// no loudness metadata, and the player does not run a loudness analysis over
// the audio. So `gainAdjustment` returns 0 dB whenever `measuredLoudness`
// is nil — the player applies no fake "measured" value. When a loudness
// source is added later (e.g. a ReplayGain tag read at download time, or a
// cached analysis pass), pass its value in and the same function does the
// right thing.

/// The loudness target, in LUFS.
let waveTargetLUFS: Double = -14

/// The most a single track's gain may be adjusted, in dB.
let waveMaxLoudnessAdjustmentDb: Double = 12

/// Gain in dB to apply so the track plays at `waveTargetLUFS`.
///
/// - Parameters:
///   - track: The track being played (kept for future per-track data; the
///     current implementation has no loudness field on `Track`).
///   - measuredLoudness: The track's measured integrated loudness in LUFS,
///     or `nil` when unknown.
/// - Returns: The dB adjustment, clamped to +/-`waveMaxLoudnessAdjustmentDb`.
///   Returns `0` when `measuredLoudness` is `nil`.
func gainAdjustment(for track: Track, measuredLoudness: Double?) -> Float {
    guard let measured = measuredLoudness, measured.isFinite else { return 0 }
    let adjustment = waveTargetLUFS - measured
    return Float(min(max(adjustment, -waveMaxLoudnessAdjustmentDb), waveMaxLoudnessAdjustmentDb))
}

/// Converts a dB gain into the linear volume multiplier AVFoundation wants.
func linearGain(fromDb db: Double) -> Float {
    Float(pow(10, db / 20))
}
