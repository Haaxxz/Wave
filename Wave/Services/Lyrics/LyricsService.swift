import Foundation

// MARK: - Lyrics service contract

/// Lyrics lookup. Implemented by `LyricsProvider` (`LyricsProvider.swift`),
/// which tries the public providers in priority order (LRCLIB first) and
/// returns `nil` when nothing is found. No API keys are needed for the
/// providers in the default chain.
///
/// The protocol requires `Sendable`: callers `await` the lookup from the
/// main actor, which sends the receiver across to the provider, and Swift 6
/// rejects a non-Sendable receiver there. `LyricsProvider` meets this with
/// an unchecked conformance (its only callers are the main actor).
protocol LyricsService: Sendable {
    func lyrics(for track: Track) async -> Lyrics?
}
