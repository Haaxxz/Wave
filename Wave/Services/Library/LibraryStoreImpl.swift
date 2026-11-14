import Foundation
import SwiftData

// MARK: - Stored models (SwiftData)

/// A liked song. The full `Track` is stored as JSON so the library can hand
/// back real tracks without re-fetching them from the network.
@Model
final class StoredTrack {
    @Attribute(.unique) var id: String
    var trackJson: Data
    var likedAt: Date

    init(track: Track, likedAt: Date = Date()) {
        self.id = track.id
        self.trackJson = (try? JSONEncoder().encode(track)) ?? Data()
        self.likedAt = likedAt
    }

    var track: Track? {
        try? JSONDecoder().decode(Track.self, from: trackJson)
    }
}

@Model
final class StoredPlaylist {
    @Attribute(.unique) var id: String
    var title: String
    var tracksJson: Data
    var createdAt: Date

    init(id: String = UUID().uuidString, title: String, tracks: [Track] = [], createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.tracksJson = (try? JSONEncoder().encode(tracks)) ?? Data()
        self.createdAt = createdAt
    }

    var tracks: [Track] {
        (try? JSONDecoder().decode([Track].self, from: tracksJson)) ?? []
    }

    var playlist: Playlist {
        Playlist(id: id, title: title, tracks: tracks)
    }
}

@Model
final class StoredDownload {
    @Attribute(.unique) var trackId: String
    var trackJson: Data
    var localPath: String
    var downloadedAt: Date
    var fileSize: Int

    init(track: Track, localURL: URL, downloadedAt: Date = Date(), fileSize: Int = 0) {
        self.trackId = track.id
        self.trackJson = (try? JSONEncoder().encode(track)) ?? Data()
        self.localPath = localURL.path
        self.downloadedAt = downloadedAt
        self.fileSize = fileSize
    }

    var downloadedTrack: DownloadedTrack? {
        guard let track = try? JSONDecoder().decode(Track.self, from: trackJson) else { return nil }
        return DownloadedTrack(
            track: track,
            localURL: URL(fileURLWithPath: localPath),
            downloadedAt: downloadedAt,
            fileSize: fileSize
        )
    }
}

/// One play event, for the Stats screen's recent history. Capped at 200.
@Model
final class StoredPlayEvent {
    var trackId: String
    var trackJson: Data
    var playedAt: Date

    init(track: Track, playedAt: Date = Date()) {
        self.trackId = track.id
        self.trackJson = (try? JSONEncoder().encode(track)) ?? Data()
        self.playedAt = playedAt
    }

    var track: Track? {
        try? JSONDecoder().decode(Track.self, from: trackJson)
    }
}

// MARK: - Library store

/// The user's library: liked songs, playlists, downloads and recent history,
/// backed by SwiftData. The store owns its own `ModelContainer`, created in
/// `init` under Application Support; if creation fails it falls back to an
/// in-memory container so the app keeps working (library changes are then
/// lost on relaunch).
@MainActor
@Observable
final class LibraryStoreImpl: LibraryStore {
    static let shared = LibraryStoreImpl(innerTube: InnerTubeClient.shared)

    private let innerTube: InnerTubeService
    private let container: ModelContainer
    private let context: ModelContext
    private let downloadManager: DownloadManager

    /// Maximum play-history events kept.
    static let maxPlayHistory = 200

    init(innerTube: InnerTubeService) {
        self.innerTube = innerTube
        let configuration = ModelConfiguration(isStoredInMemoryOnly: false)
        if let created = try? ModelContainer(
            for: StoredTrack.self, StoredPlaylist.self, StoredDownload.self, StoredPlayEvent.self,
            configurations: configuration
        ) {
            self.container = created
        } else {
            // Fall back to an in-memory store rather than crashing at launch.
            self.container = try! ModelContainer(
                for: StoredTrack.self, StoredPlaylist.self, StoredDownload.self, StoredPlayEvent.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        self.context = ModelContext(container)
        self.downloadManager = DownloadManager(innerTube: innerTube, lyrics: LyricsProvider.shared)
    }

    var likedSongs: [Track] {
        let descriptor = FetchDescriptor<StoredTrack>(sortBy: [SortDescriptor(\.likedAt, order: .reverse)])
        let stored = (try? context.fetch(descriptor)) ?? []
        return stored.compactMap(\.track)
    }

    var playlists: [Playlist] {
        let descriptor = FetchDescriptor<StoredPlaylist>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        let stored = (try? context.fetch(descriptor)) ?? []
        return stored.map(\.playlist)
    }

    var downloadedTracks: [DownloadedTrack] {
        let descriptor = FetchDescriptor<StoredDownload>(sortBy: [SortDescriptor(\.downloadedAt, order: .reverse)])
        let stored = (try? context.fetch(descriptor)) ?? []
        return stored.compactMap(\.downloadedTrack)
    }

    /// Recently played tracks, newest first (last 200 plays). Feeds Stats.
    var recentPlayed: [Track] {
        let descriptor = FetchDescriptor<StoredPlayEvent>(sortBy: [SortDescriptor(\.playedAt, order: .reverse)])
        let stored = (try? context.fetch(descriptor)) ?? []
        return stored.compactMap(\.track)
    }

    /// Download progress by track id, forwarded from the download manager.
    var downloadProgress: [String: Double] {
        downloadManager.progress
    }

    func isLiked(_ track: Track) -> Bool {
        let id = track.id
        let descriptor = FetchDescriptor<StoredTrack>(predicate: #Predicate { $0.id == id })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    func isDownloaded(_ track: Track) -> Bool {
        let id = track.id
        let descriptor = FetchDescriptor<StoredDownload>(predicate: #Predicate { $0.trackId == id })
        guard let stored = try? context.fetch(descriptor), let first = stored.first else { return false }
        return FileManager.default.fileExists(atPath: first.localPath)
    }

    func localURL(for track: Track) -> URL? {
        let id = track.id
        let descriptor = FetchDescriptor<StoredDownload>(predicate: #Predicate { $0.trackId == id })
        guard let stored = try? context.fetch(descriptor), let first = stored.first else { return nil }
        let url = URL(fileURLWithPath: first.localPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func toggleLike(_ track: Track) async {
        let id = track.id
        let descriptor = FetchDescriptor<StoredTrack>(predicate: #Predicate { $0.id == id })
        if let existing = try? context.fetch(descriptor), let first = existing.first {
            context.delete(first)
            save()
            // Best-effort server sync; a logged-out user simply skips it.
            try? await innerTube.like(videoId: id, status: .none)
        } else {
            context.insert(StoredTrack(track: track))
            save()
            try? await innerTube.like(videoId: id, status: .liked)
        }
    }

    func createPlaylist(title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        context.insert(StoredPlaylist(title: trimmed))
        save()
    }

    func addToPlaylist(_ track: Track, playlistId: String) async {
        let descriptor = FetchDescriptor<StoredPlaylist>(predicate: #Predicate { $0.id == playlistId })
        guard let stored = try? context.fetch(descriptor), let playlist = stored.first else { return }
        var tracks = playlist.tracks
        guard !tracks.contains(where: { $0.id == track.id }) else { return }
        tracks.append(track)
        playlist.tracksJson = (try? JSONEncoder().encode(tracks)) ?? Data()
        save()
    }

    func download(_ track: Track) async {
        if isDownloaded(track) { return }
        do {
            let url = try await downloadManager.download(track)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let id = track.id
            let descriptor = FetchDescriptor<StoredDownload>(predicate: #Predicate { $0.trackId == id })
            if let existing = try? context.fetch(descriptor), let first = existing.first {
                first.localPath = url.path
                first.downloadedAt = Date()
                first.fileSize = size
            } else {
                context.insert(StoredDownload(track: track, localURL: url, fileSize: size))
            }
            save()
        } catch {
            // The download failed; nothing is recorded. The UI reads
            // `downloadProgress` while the download runs.
        }
    }

    func deleteDownload(_ track: Track) async {
        let id = track.id
        let descriptor = FetchDescriptor<StoredDownload>(predicate: #Predicate { $0.trackId == id })
        guard let stored = try? context.fetch(descriptor) else { return }
        for entry in stored {
            try? FileManager.default.removeItem(atPath: entry.localPath)
            // Remove the .lrc sidecar alongside the audio file.
            let lrc = URL(fileURLWithPath: entry.localPath)
                .deletingPathExtension()
                .appendingPathExtension("lrc")
            try? FileManager.default.removeItem(at: lrc)
            context.delete(entry)
        }
        save()
    }

    /// Records a play for the Stats screen's recent history. Called by the
    /// player on every track start. Keeps the newest 200 events.
    func recordPlayed(_ track: Track) {
        context.insert(StoredPlayEvent(track: track))
        let descriptor = FetchDescriptor<StoredPlayEvent>(sortBy: [SortDescriptor(\.playedAt, order: .forward)])
        if let all = try? context.fetch(descriptor), all.count > Self.maxPlayHistory {
            for stale in all.prefix(all.count - Self.maxPlayHistory) {
                context.delete(stale)
            }
        }
        save()
    }

    private func save() {
        try? context.save()
    }
}
