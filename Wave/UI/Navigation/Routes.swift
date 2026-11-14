import SwiftUI

// MARK: - Navigation

/// One case per destination in the app (30 screens, mirroring the Android
/// NavGraph). Screens take their id from the route and load their own data.
enum Route: Hashable {
    case feed
    case discover
    case genres
    case search
    case artist(id: String)
    case album(id: String)
    case playlist(id: String)
    case library
    case stats
    case settings
    case audioSettings
    case appearanceSettings
    case autoEQ
    case downloadSettings
    case storage
    case modules
    case excludedSongs
    case homeSections
    case downloads
    case friendProfile(userId: String)
    case jam
    case podcasts
    case podcastShow(id: String)
    case newReleases
    case generate
    case youtubeLogin
    case spotifyLogin
    case playlistImport
    case lyricsShare(track: Track, lyrics: Lyrics)
}

enum AppTab: Hashable {
    case feed
    case search
    case library
    case stats
}

/// One navigation path per tab, plus the selected tab. Owned by ContentView.
@Observable
final class AppRouter {
    var selectedTab: AppTab = .feed
    var feedPath = NavigationPath()
    var searchPath = NavigationPath()
    var libraryPath = NavigationPath()
    var statsPath = NavigationPath()

    func navigate(_ route: Route, in tab: AppTab) {
        selectedTab = tab
        switch tab {
        case .feed: feedPath.append(route)
        case .search: searchPath.append(route)
        case .library: libraryPath.append(route)
        case .stats: statsPath.append(route)
        }
    }

    func popToRoot(in tab: AppTab) {
        switch tab {
        case .feed: feedPath = NavigationPath()
        case .search: searchPath = NavigationPath()
        case .library: libraryPath = NavigationPath()
        case .stats: statsPath = NavigationPath()
        }
    }
}

/// Builds the destination view for a route. Every screen is constructed here
/// so the tab shells stay thin.
struct RouteView: View {
    var route: Route

    var body: some View {
        switch route {
        case .feed:
            FeedView()
        case .discover:
            DiscoverView()
        case .genres:
            GenresView()
        case .search:
            SearchView()
        case .artist(let id):
            ArtistView(id: id)
        case .album(let id):
            AlbumView(id: id)
        case .playlist(let id):
            PlaylistView(id: id)
        case .library:
            LibraryView()
        case .stats:
            StatsView()
        case .settings:
            SettingsView()
        case .audioSettings:
            AudioSettingsView()
        case .appearanceSettings:
            AppearanceSettingsView()
        case .autoEQ:
            AutoEQView()
        case .downloadSettings:
            DownloadSettingsView()
        case .storage:
            StorageView()
        case .modules:
            ModulesView()
        case .excludedSongs:
            ExcludedSongsView()
        case .homeSections:
            HomeSectionsView()
        case .downloads:
            DownloadsView()
        case .friendProfile(let userId):
            FriendProfileView(userId: userId)
        case .jam:
            JamView()
        case .podcasts:
            PodcastsView()
        case .podcastShow(let id):
            PodcastShowView(id: id)
        case .newReleases:
            NewReleasesView()
        case .generate:
            GenerateView()
        case .youtubeLogin:
            YouTubeLoginView()
        case .spotifyLogin:
            SpotifyLoginView()
        case .playlistImport:
            PlaylistImportView()
        case .lyricsShare(let track, let lyrics):
            LyricsShareView(track: track, lyrics: lyrics)
        }
    }
}
