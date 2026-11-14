import Foundation

// MARK: - Lyrics service contract

/// Lyrics lookup. Implemented by `LyricsProvider` (`LyricsProvider.swift`),
/// which tries the public providers in priority order (LRCLIB first) and
/// returns `nil` when nothing is found. No API keys are needed for the
/// providers in the default chain.
///
/// All consumers (Player and DownloadManager) access the service from the
/// main actor, so encode that isolation in the contract rather than allowing
/// a main-actor-owned service reference to cross into a nonisolated method.
@MainActor
protocol LyricsService {
    func lyrics(for track: Track) async -> Lyrics?
}
