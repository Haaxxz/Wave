import Foundation

// MARK: - Library store contract

/// The user's library: liked songs, playlists and downloads. Implemented by
/// `LibraryStoreImpl` (`LibraryStoreImpl.swift`, SwiftData). The download
/// engine itself is `DownloadManager` (`DownloadManager.swift`).
@MainActor
protocol LibraryStore: AnyObject, Observable {
    var likedSongs: [Track] { get }
    var playlists: [Playlist] { get }
    var downloadedTracks: [DownloadedTrack] { get }

    func toggleLike(_ track: Track) async
    func createPlaylist(title: String) async
    func addToPlaylist(_ track: Track, playlistId: String) async
    func download(_ track: Track) async
    func deleteDownload(_ track: Track) async
}
