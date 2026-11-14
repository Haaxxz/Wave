# Contracts — exact names every module must use

This file is the assembly contract. If a type or function is listed here,
implement it with exactly this name and signature. Do not rename, and do
not invent a parallel type.

## Models — `Wave/Models/Models.swift`

- `Thumbnail(url: URL?, width: Int, height: Int)` — struct, Sendable.
- `ArtistRef(id: String, name: String, thumbnails: [Thumbnail])`
- `AlbumRef(id: String, title: String, thumbnails: [Thumbnail])`
- `Track(id: String, title: String, artists: [ArtistRef], album: AlbumRef?, durationSeconds: Int?, thumbnails: [Thumbnail], isVideo: Bool, explicit: Bool, likeStatus: LikeStatus, playCount: Int?)`
- `LikeStatus` — enum: `none`, `liked`, `disliked`.
- `Album(id: String, title: String, artists: [ArtistRef], year: Int?, thumbnails: [Thumbnail], tracks: [Track], description: String?)`
- `ArtistDetail(id: String, name: String, thumbnails: [Thumbnail], subscribers: String?, topSongs: [Track], albums: [AlbumRef], singles: [AlbumRef], playlists: [PlaylistRef])`
- `PlaylistRef(id: String, title: String, author: String?, thumbnails: [Thumbnail], trackCount: Int?)`
- `Playlist(id: String, title: String, author: String?, thumbnails: [Thumbnail], tracks: [Track], description: String?)`
- `FeedSection(title: String, browseId: String?, items: [FeedItem])`
- `FeedItem` — enum with associated values: `track(Track)`, `album(AlbumRef)`, `artist(ArtistRef)`, `playlist(PlaylistRef)`.
- `SearchResults(songs: [Track], albums: [AlbumRef], artists: [ArtistRef], playlists: [PlaylistRef], videos: [Track])`
- `LyricsLine(startMs: Int, endMs: Int, text: String)`
- `Lyrics(synced: [LyricsLine]?, plainText: String?, source: String)`
- `StreamInfo(videoId: String, formats: [AudioFormat], durationSeconds: Int?, isLive: Bool)`
- `AudioFormat(url: URL, itag: Int, mimeType: String, bitrate: Int, contentLength: Int?, isAdaptive: Bool)`
- `QueueItem(id: UUID, track: Track)`
- `JamRoom(code: String, name: String, hostName: String, members: [String], currentTrack: Track?, positionMs: Int, isPlaying: Bool)`
- `DownloadedTrack(track: Track, localURL: URL, downloadedAt: Date, fileSize: Int)`

## Services — protocols in `Wave/Services/*/`

### InnerTube — `InnerTubeService.swift`

```swift
protocol InnerTubeService: Sendable {
    func home() async throws -> [FeedSection]
    func search(query: String) async throws -> SearchResults
    func suggestions(query: String) async throws -> [String]
    func artist(id: String) async throws -> ArtistDetail
    func album(id: String) async throws -> Album
    func playlist(id: String) async throws -> Playlist
    func next(videoId: String, playlistId: String?) async throws -> [Track]
    func player(videoId: String) async throws -> StreamInfo
    func like(videoId: String, status: LikeStatus) async throws
    func charts(country: String) async throws -> [FeedSection]
    func newReleases() async throws -> [AlbumRef]
    func genres() async throws -> [FeedSection]
}
```

Concrete type: `InnerTubeClient` in `InnerTubeClient.swift`, a
`@MainActor @Observable final class` (it must be `@Observable` so SwiftUI
can inject it with `.environment`). It takes no
arguments in `init()`; it reads the visitor data / poToken from
`PoTokenGenerator.shared` and the login cookies from `YouTubeSession.shared`.
`static let shared = InnerTubeClient()`.

### poToken — `PoTokenGenerator.swift`

```swift
final class PoTokenGenerator: Sendable {
    static let shared = PoTokenGenerator()
    var visitorData: String? { get }
    func token() async throws -> String
}
```

### Playback — `PlaybackEngine.swift`

```swift
enum RepeatMode { case off, all, one }
enum PlayerState { case idle, loading, playing, paused, stopped, failed(Error) }

@MainActor
protocol PlaybackEngine: AnyObject, Observable {
    var state: PlayerState { get }
    var currentTrack: Track? { get }
    var queue: [QueueItem] { get }
    var queueIndex: Int { get }
    var positionSeconds: Double { get }
    var durationSeconds: Double { get }
    var isShuffleEnabled: Bool { get set }
    var repeatMode: RepeatMode { get set }
    func play(_ track: Track)
    func playAll(_ tracks: [Track], startingAt index: Int)
    func togglePlayPause()
    func next()
    func previous()
    func seek(to seconds: Double)
    func addToQueue(_ track: Track)
    func removeFromQueue(at offsets: IndexSet)
    func moveQueue(from source: IndexSet, to destination: Int)
    func startRadio(for track: Track) async
}
```

Concrete type: `Player` in `Player.swift`. `init(innerTube: InnerTubeService, lyrics: LyricsService)`.
`static let shared = Player(innerTube: InnerTubeClient.shared, lyrics: LyricsProvider.shared)`.
The player owns the
`AVPlayer`/`AVAudioEngine`, the Now Playing info, remote commands, the
sleep timer (`setSleepTimer(minutes:)` / `cancelSleepTimer()`), the EQ
(`EQSettings` in `Equalizer.swift`), and loudness normalisation. Keep all
of that behind this protocol — the UI never touches AVFoundation directly.

### Lyrics — `LyricsService.swift`

```swift
protocol LyricsService {
    func lyrics(for track: Track) async -> Lyrics?
}
```

Concrete type: `LyricsProvider` (LRCLIB first, then the other public
providers in priority order). Returns `nil` when nothing is found.
`init()` with no arguments. `static let shared = LyricsProvider()`.
`@Observable` so SwiftUI can inject it. The protocol does not require
`Sendable` — its only consumers are `@MainActor` (the Player and the
DownloadManager).

### Library — `LibraryStore.swift`

```swift
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
```

Concrete type: `LibraryStoreImpl` (SwiftData). `init(innerTube: InnerTubeService)`.
`static let shared = LibraryStoreImpl(innerTube: InnerTubeClient.shared)`.
The download engine is
`DownloadManager` in `DownloadManager.swift`.

### Jam — `JamService.swift`

```swift
@MainActor
protocol JamService: AnyObject, Observable {
    var room: JamRoom? { get }
    var isConnected: Bool { get }
    func createRoom(name: String) async throws -> String  // returns the join code
    func join(code: String) async throws
    func leave() async
    func sendPlay() async
    func sendPause() async
    func sendSeek(toMs: Int) async
    func sendQueueAdd(_ track: Track) async
}
```

Concrete type: `JamClient` in `JamClient.swift`. `init(player: Player)`.
`static let shared = JamClient(player: Player.shared)`.

## Shared helpers (used across modules — exact names)

- `WidgetSnapshotWriter` (`Wave/Services/Settings/WidgetSnapshotWriter.swift`):
  `enum WidgetSnapshotWriter { static func write(_ snapshot: WaveWidgetSnapshot) }`.
  Writes the snapshot JSON to the shared App Group defaults
  (`group.app.wave`) when the group exists; silently does nothing when it
  does not. The Player calls it on every track change and every 15 seconds
  while playing.
- `LastFmService` (`Wave/Services/Social/LastFmService.swift`):
  `final class LastFmService { static let shared = LastFmService(); var isConfigured: Bool { get }; func scrobble(track: Track) async }`.
  `isConfigured` is true when a Last.fm API key is set in SettingsStore.
  The Player calls `scrobble` at the halfway point of a track.
- `SpotifyService` (`Wave/Services/Social/SpotifyService.swift`):
  `final class SpotifyService { static let shared = SpotifyService(); func importPlaylist(url: String) async throws -> Playlist; func likedSongs() async throws -> [Track] }`.
  Uses the Spotify Web API with the client id/secret from SettingsStore.
- `YouTubeWebView` (`Wave/Services/InnerTube/YouTubeWebView.swift`):
  `struct YouTubeWebView: UIViewRepresentable { var onLoginComplete: (String?) -> Void }`.
  Loads the YouTube Music login page; when the session cookies show a
  logged-in user, calls `onLoginComplete` with the account display name
  (or `nil` on failure/cancel).

### Settings — `SettingsStore.swift` (written in the scaffold)

`@MainActor @Observable final class SettingsStore` with `static let shared`.
Published properties the UI binds to: `isLoggedIn`, `userName`,
`audioQuality`, `downloadQuality`, `autoEQEnabled`, `selectedHeadphone`,
`automixEnabled`, `loudnessNormalizationEnabled`, `skipSilenceEnabled`,
`sleepTimerMinutes`, `theme`, `accentColor`, `lastFmApiKey`,
`spotifyClientId`, `homeSections`, `excludedSongIds`. All persisted in
`UserDefaults` (suite `app.wave.settings`).

## UI — `Wave/UI/`

- `WaveApp.swift` — `@main struct WaveApp: App`. Injects the shared
  singletons with `.environment(...)`: `SettingsStore.shared`,
  `Player.shared`, `InnerTubeClient.shared`, `LibraryStoreImpl.shared`,
  `JamClient.shared`, `LyricsProvider.shared`. Screens read them as
  concrete types, e.g. `@Environment(Player.self)`.
- `ContentView.swift` — the main shell: `TabView` with tabs Feed, Search,
  Library, Stats, and the mini player above the tab bar. Holds the
  `NavigationStack` per tab and the full-player sheet.
- `Routes.swift` — `enum Route: Hashable` with one case per destination
  (see `docs/SPECS.md` for the 30 destinations). `AppRouter` is an
  `@Observable` class holding a `NavigationPath` per tab.
- `Theme.swift` — `WaveColors`, `WaveFonts`, `glassBackground()` view
  modifier (`.glassEffect` on iOS 26, `.ultraThinMaterial` below), and
  `ArtworkView` (async image with placeholder).
- Screens in `Wave/UI/Screens/`, one file per screen, named
  `<Name>View.swift` with a `struct <Name>View: View`. Exact names:
  `SplashView`, `LoginView`, `FeedView`, `DiscoverView`, `GenresView`,
  `SearchView`, `ArtistView(id: String)`, `AlbumView(id: String)`,
  `PlaylistView(id: String)`, `LibraryView`, `StatsView`, `SettingsView`,
  `AudioSettingsView`, `AppearanceSettingsView`, `AutoEQView`,
  `DownloadSettingsView`, `StorageView`, `ModulesView`,
  `ExcludedSongsView`, `HomeSectionsView`, `DownloadsView`,
  `FriendProfileView(userId: String)`, `JamView`, `PodcastsView`,
  `PodcastShowView(id: String)`, `NewReleasesView`, `GenerateView`,
  `YouTubeLoginView`, `SpotifyLoginView`, `PlaylistImportView`,
  `LyricsShareView(track: Track, lyrics: Lyrics)`.
- Player UI in `Wave/UI/Player/`: `MiniPlayerView`, `FullPlayerView`,
  `QueueView`, `LyricsSheetView`.

Every screen takes its dependencies from the environment
(`@Environment(Player.self)` etc.) — never constructs services itself.
Screens that need an id take it as an `init` parameter and load their own
data in `.task`.

## Widgets — `WaveWidgets/`

- `WaveWidgets.swift` — `@main struct WaveWidgets: WidgetBundle` with
  `NowPlayingWidget` and `WaveWidget`. Timeline reads the shared
  `UserDefaults(suiteName: "group.app.wave")` snapshot written by the app
  (`WaveWidgetSnapshot` in `Wave/Services/Settings/`); when the group is
  not configured, the widget shows its placeholder state.

## Tests — `WaveTests/`

One test file per unit: `InnerTubeParsingTests`, `SignatureDecipherTests`,
`LyricsParsingTests`, `EqualizerTests`, `JamProtocolTests`. Tests must not
touch the network — use the bundled JSON fixtures in `WaveTests/Fixtures/`.
