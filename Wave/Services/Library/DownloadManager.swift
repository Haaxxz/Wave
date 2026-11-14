import Foundation

// MARK: - Lyrics service contract

/// Lyrics lookup. Implemented by `LyricsProvider` (`LyricsProvider.swift`),
/// which tries the public providers in priority order (LRCLIB first) and
/// returns `nil` when nothing is found. No API keys are needed for the
/// providers in the default chain.
///
/// The protocol deliberately does NOT require `Sendable`: the only
/// consumers are `@MainActor` (the Player and the DownloadManager), and
/// requiring it would force the provider into an actor or an unchecked
/// conformance for no benefit.
@MainActor
protocol LyricsService {
    func lyrics(for track: Track) async -> Lyrics?
}

