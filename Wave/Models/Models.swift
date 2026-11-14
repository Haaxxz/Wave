import Foundation

// MARK: - Shared data models
//
// Plain structs only. No UIKit, no SwiftUI, no service references.
// These compile in both the app target and the widget extension target.

struct Thumbnail: Sendable, Codable, Hashable {
    var url: URL?
    var width: Int
    var height: Int

    init(url: URL? = nil, width: Int = 0, height: Int = 0) {
        self.url = url
        self.width = width
        self.height = height
    }

    /// The thumbnail closest to the requested width, preferring larger ones.
    static func best(in thumbnails: [Thumbnail], preferWidth: Int = 512) -> Thumbnail? {
        guard !thumbnails.isEmpty else { return nil }
        return thumbnails
            .sorted { abs($0.width - preferWidth) < abs($1.width - preferWidth) }
            .first
    }
}

enum LikeStatus: String, Sendable, Codable, Hashable {
    case none
    case liked
    case disliked
}

struct ArtistRef: Sendable, Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var thumbnails: [Thumbnail]

    init(id: String, name: String, thumbnails: [Thumbnail] = []) {
        self.id = id
        self.name = name
        self.thumbnails = thumbnails
    }
}

struct AlbumRef: Sendable, Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var thumbnails: [Thumbnail]

    init(id: String, title: String, thumbnails: [Thumbnail] = []) {
        self.id = id
        self.title = title
        self.thumbnails = thumbnails
    }
}

struct Track: Sendable, Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var artists: [ArtistRef]
    var album: AlbumRef?
    var durationSeconds: Int?
    var thumbnails: [Thumbnail]
    var isVideo: Bool
    var explicit: Bool
    var likeStatus: LikeStatus
    var playCount: Int?

    init(
        id: String,
        title: String,
        artists: [ArtistRef] = [],
        album: AlbumRef? = nil,
        durationSeconds: Int? = nil,
        thumbnails: [Thumbnail] = [],
        isVideo: Bool = false,
        explicit: Bool = false,
        likeStatus: LikeStatus = .none,
        playCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.durationSeconds = durationSeconds
        self.thumbnails = thumbnails
        self.isVideo = isVideo
        self.explicit = explicit
        self.likeStatus = likeStatus
        self.playCount = playCount
    }

    var artistNames: String {
        artists.map(\.name).joined(separator: ", ")
    }

    var artworkURL: URL? {
        Thumbnail.best(in: thumbnails)?.url
    }
}

struct Album: Sendable, Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var artists: [ArtistRef]
    var year: Int?
    var thumbnails: [Thumbnail]
    var tracks: [Track]
    var description: String?

    init(
        id: String,
        title: String,
        artists: [ArtistRef] = [],
        year: Int? = nil,
        thumbnails: [Thumbnail] = [],
        tracks: [Track] = [],
        description: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.year = year
        self.thumbnails = thumbnails
        self.tracks = tracks
        self.description = description
    }
}

struct ArtistDetail: Sendable, Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var thumbnails: [Thumbnail]
    var subscribers: String?
    var topSongs: [Track]
    var albums: [AlbumRef]
    var singles: [AlbumRef]
    var playlists: [PlaylistRef]

    init(
        id: String,
        name: String,
        thumbnails: [Thumbnail] = [],
        subscribers: String? = nil,
        topSongs: [Track] = [],
        albums: [AlbumRef] = [],
        singles: [AlbumRef] = [],
        playlists: [PlaylistRef] = []
    ) {
        self.id = id
        self.name = name
        self.thumbnails = thumbnails
        self.subscribers = subscribers
        self.topSongs = topSongs
        self.albums = albums
        self.singles = singles
        self.playlists = playlists
    }
}

struct PlaylistRef: Sendable, Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var author: String?
    var thumbnails: [Thumbnail]
    var trackCount: Int?

    init(id: String, title: String, author: String? = nil, thumbnails: [Thumbnail] = [], trackCount: Int? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.thumbnails = thumbnails
        self.trackCount = trackCount
    }
}

struct Playlist: Sendable, Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var author: String?
    var thumbnails: [Thumbnail]
    var tracks: [Track]
    var description: String?

    init(
        id: String,
        title: String,
        author: String? = nil,
        thumbnails: [Thumbnail] = [],
        tracks: [Track] = [],
        description: String? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.thumbnails = thumbnails
        self.tracks = tracks
        self.description = description
    }
}

enum FeedItem: Sendable, Codable, Hashable {
    case track(Track)
    case album(AlbumRef)
    case artist(ArtistRef)
    case playlist(PlaylistRef)
}

struct FeedSection: Sendable, Codable, Hashable, Identifiable {
    var id: String { title + (browseId ?? "") }
    var title: String
    var browseId: String?
    var items: [FeedItem]

    init(title: String, browseId: String? = nil, items: [FeedItem] = []) {
        self.title = title
        self.browseId = browseId
        self.items = items
    }
}

struct SearchResults: Sendable, Codable, Hashable {
    var songs: [Track]
    var albums: [AlbumRef]
    var artists: [ArtistRef]
    var playlists: [PlaylistRef]
    var videos: [Track]

    init(
        songs: [Track] = [],
        albums: [AlbumRef] = [],
        artists: [ArtistRef] = [],
        playlists: [PlaylistRef] = [],
        videos: [Track] = []
    ) {
        self.songs = songs
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.videos = videos
    }

    var isEmpty: Bool {
        songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty && videos.isEmpty
    }
}

struct LyricsLine: Sendable, Codable, Hashable {
    var startMs: Int
    var endMs: Int
    var text: String

    init(startMs: Int, endMs: Int, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

struct Lyrics: Sendable, Codable, Hashable {
    var synced: [LyricsLine]?
    var plainText: String?
    var source: String

    init(synced: [LyricsLine]? = nil, plainText: String? = nil, source: String = "") {
        self.synced = synced
        self.plainText = plainText
        self.source = source
    }

    /// The line active at the given playback position, if any.
    func line(at positionMs: Int) -> LyricsLine? {
        guard let synced else { return nil }
        return synced.last { $0.startMs <= positionMs }
    }
}

struct AudioFormat: Sendable, Codable, Hashable {
    var url: URL
    var itag: Int
    var mimeType: String
    var bitrate: Int
    var contentLength: Int?
    var isAdaptive: Bool

    init(url: URL, itag: Int, mimeType: String, bitrate: Int, contentLength: Int? = nil, isAdaptive: Bool = true) {
        self.url = url
        self.itag = itag
        self.mimeType = mimeType
        self.bitrate = bitrate
        self.contentLength = contentLength
        self.isAdaptive = isAdaptive
    }
}

struct StreamInfo: Sendable, Codable, Hashable {
    var videoId: String
    var formats: [AudioFormat]
    var durationSeconds: Int?
    var isLive: Bool

    init(videoId: String, formats: [AudioFormat] = [], durationSeconds: Int? = nil, isLive: Bool = false) {
        self.videoId = videoId
        self.formats = formats
        self.durationSeconds = durationSeconds
        self.isLive = isLive
    }
}

struct QueueItem: Sendable, Hashable, Identifiable {
    var id: UUID
    var track: Track

    init(track: Track) {
        self.id = UUID()
        self.track = track
    }
}

struct JamRoom: Sendable, Hashable {
    var code: String
    var name: String
    var hostName: String
    var members: [String]
    var currentTrack: Track?
    var positionMs: Int
    var isPlaying: Bool

    init(
        code: String,
        name: String,
        hostName: String,
        members: [String] = [],
        currentTrack: Track? = nil,
        positionMs: Int = 0,
        isPlaying: Bool = false
    ) {
        self.code = code
        self.name = name
        self.hostName = hostName
        self.members = members
        self.currentTrack = currentTrack
        self.positionMs = positionMs
        self.isPlaying = isPlaying
    }
}

struct DownloadedTrack: Sendable, Codable, Hashable, Identifiable {
    var id: String { track.id }
    var track: Track
    var localURL: URL
    var downloadedAt: Date
    var fileSize: Int

    init(track: Track, localURL: URL, downloadedAt: Date = Date(), fileSize: Int = 0) {
        self.track = track
        self.localURL = localURL
        self.downloadedAt = downloadedAt
        self.fileSize = fileSize
    }
}

/// The snapshot the app writes for the widget extension. Lives in the shared
/// App Group container when configured (`group.app.wave`), otherwise the
/// widget shows its placeholder state.
struct WaveWidgetSnapshot: Sendable, Codable {
    var trackTitle: String?
    var artistName: String?
    var artworkURL: URL?
    var isPlaying: Bool
    var positionSeconds: Double
    var durationSeconds: Double
    var updatedAt: Date

    init(
        trackTitle: String? = nil,
        artistName: String? = nil,
        artworkURL: URL? = nil,
        isPlaying: Bool = false,
        positionSeconds: Double = 0,
        durationSeconds: Double = 0,
        updatedAt: Date = Date()
    ) {
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.artworkURL = artworkURL
        self.isPlaying = isPlaying
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.updatedAt = updatedAt
    }
}
