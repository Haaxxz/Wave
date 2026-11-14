import Foundation
import CryptoKit

// MARK: - InnerTube service contract

/// The YouTube Music API surface the app needs. Implemented by
/// `InnerTubeClient` (actor). All calls are `async throws`; the client
/// handles retries, visitor data and poToken internally.
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

// MARK: - YouTube session

/// The logged-in YouTube session. The login WebView writes its cookies into
/// the shared `HTTPCookieStorage`; this type reads back the pieces the API
/// client needs — login state and the SAPISIDHASH authorisation header for
/// authenticated calls.
final class YouTubeSession: Sendable {
    static let shared = YouTubeSession()

    private init() {}

    var isLoggedIn: Bool {
        cookie(named: "SAPISID") != nil
    }

    var visitorData: String? {
        UserDefaults.standard.string(forKey: "visitorData")
    }

    /// `SAPISIDHASH <timestamp>_<sha1>` — SHA-1 of
    /// `<timestamp> <SAPISID> https://music.youtube.com`.
    func sapisidHash() -> String? {
        guard let sapisid = cookie(named: "SAPISID") else { return nil }
        let timestamp = Int(Date().timeIntervalSince1970)
        let input = "\(timestamp) \(sapisid) https://music.youtube.com"
        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }

    func cookie(named name: String) -> String? {
        HTTPCookieStorage.shared.cookies?
            .first { $0.name == name && $0.domain.contains("youtube.com") }?
            .value
    }
}
