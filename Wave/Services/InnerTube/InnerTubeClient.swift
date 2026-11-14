import Foundation

// MARK: - Shared InnerTube constants

/// Public constants for the YouTube Music InnerTube surface. The API key
/// and client version are bootstrapped from music.youtube.com at runtime
/// (exactly like the Android app's `fetchWebConfig`); the values below
/// are only fallbacks. Both keys are the *public web-client keys* YouTube
/// ships to every browser inside its own pages (`INNERTUBE_API_KEY`) —
/// they identify the web client, they are not account credentials.
enum InnerTubeConstants {
    static let musicAPI = "https://music.youtube.com/youtubei/v1"
    static let youtubeAPI = "https://www.youtube.com/youtubei/v1"
    static let musicOrigin = "https://music.youtube.com"
    static let youtubeOrigin = "https://www.youtube.com"

    static let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"
    static let desktopUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let consentCookie = "CONSENT=YES+cb.20210328-17-p0.en+FX+100; SOCS=CAISEwgDEgk0ODE3Nzk3MjQaAmVuIAEaBgiA_LyaBg"

    static let fallbackAPIKey = "AIzaSyC9XL3ZjWddXya6X74sNWrlRQ11ZlFhT4M"
    static let fallbackClientVersion = "1.20260707.12.00"
    static let webAPIKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    static let webClientVersion = "2.20261011.05.00"
    /// The jnn BotGuard endpoints use the public WEB client key.
    static let jnnAPIKey = webAPIKey

    static let clientIDs: [String: String] = [
        "WEB": "1",
        "WEB_REMIX": "67",
        "IOS": "5",
        "IOS_MUSIC": "26",
        "ANDROID": "3",
        "ANDROID_MUSIC": "21",
        "TVHTML5": "7",
        "TVHTML5_SIMPLY_EMBEDDED_PLAYER": "85",
        "WEB_EMBEDDED_PLAYER": "56",
        "MWEB": "62",
    ]

    /// Mirrors Android `isValidVisitorData`: long enough, allowed
    /// characters, and not the synthetic session placeholder.
    static func isValidVisitorData(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        if token == "lastwave_session" { return false }
        if token.count < 15 { return false }
        return token.allSatisfy { $0.isLetter || $0.isNumber || "+/=-_%~".contains($0) }
    }
}

/// The bootstrapped web configuration: API key, client version, and the
/// visitor data scraped from the homepage (or fetched from `visitor_id`).
struct InnerTubeWebConfig: Sendable {
    let apiKey: String
    let clientVersion: String
    let visitorData: String?
}

enum InnerTubeError: Error, Sendable {
    case network
    case http(Int)
    case invalidResponse
    case notLoggedIn
    case emptyResponse
}

// MARK: - InnerTube client
//
// Swift port of the Android `InnerTubeMusicApi` (WEB_REMIX client).
// Requests are POSTs with a JSON body containing `context.client`; the
// API key and client version are bootstrapped from music.youtube.com and
// cached, falling back to the public constants above. Authenticated calls
// add the SAPISIDHASH header from `YouTubeSession`; cookies ride along
// automatically through the shared URLSession cookie storage.

@MainActor
@Observable
final class InnerTubeClient: InnerTubeService {
    static let shared = InnerTubeClient()

    // Search `params` filters, copied from the Android client.
    private static let songSearchFilter = "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
    private static let artistSearchFilter = "EgWKAQIgAWoKEAkQBRAKEAMQBA=="
    private static let albumSearchFilter = "EgWKAQIYAWoKEAkQBRAKEAMQBA=="
    private static let videoSearchFilter = "EgWKAQIQAWoKEAkQBRAKEAMQBA=="
    private static let playlistSearchFilter = "Eg-KAQwIABAAGAAgACgB"

    private let session = URLSession.shared
    private var cachedConfig: InnerTubeWebConfig?
    private var lastConfigFetch: Date?
    private var streamResolver: StreamResolver?

    init() {}

    /// The stream resolver, created on first use (it holds a weak
    /// reference back to this client, so it cannot be built in `init`).
    private func resolver() -> StreamResolver {
        if let streamResolver { return streamResolver }
        let resolver = StreamResolver(client: self)
        self.streamResolver = resolver
        return resolver
    }

    // MARK: - Protocol: home

    func home() async throws -> [FeedSection] {
        let root = try await browseRoot(browseId: "FEmusic_home")
        return InnerTubeParsing.parseFeedSections(in: root)
    }

    // MARK: - Protocol: search

    func search(query: String) async throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResults() }
        async let songs = searchSongs(trimmed)
        async let artists = searchEntities(trimmed, kind: .artist)
        async let albums = searchEntities(trimmed, kind: .album)
        async let playlists = searchPlaylists(trimmed)
        async let videos = searchVideos(trimmed)
        return SearchResults(
            songs: await songs,
            albums: await albums.map { AlbumRef(id: $0.id, title: $0.name, thumbnails: $0.thumbnails) },
            artists: await artists.map { ArtistRef(id: $0.id, name: $0.name, thumbnails: $0.thumbnails) },
            playlists: await playlists,
            videos: await videos
        )
    }

    func suggestions(query: String) async throws -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        // Mirrors Android `SearchRepository.getSuggestions`: the google
        // endpoint first, the YouTube clients6 endpoint as fallback.
        let urls = [
            "https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&q=\(encoded)",
            "https://suggestqueries-clients6.youtube.com/complete/search?client=firefox&ds=yt&q=\(encoded)",
        ]
        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.setValue(InnerTubeConstants.webUserAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try? JSONValue(data: data),
                  let suggestions = json.asArray?.dropFirst().first?.asArray else {
                continue
            }
            let parsed = suggestions.compactMap { $0.asString }
            if !parsed.isEmpty { return parsed }
        }
        return []
    }

    // MARK: - Protocol: detail pages

    func artist(id: String) async throws -> ArtistDetail {
        let root = try await browseRoot(browseId: id)
        var detail = InnerTubeParsing.parseArtistDetail(id: id, in: root)
        // The overview only embeds a few top tracks; follow the shelf's
        // "more" endpoint for the full list, like the Android client.
        if detail.topSongs.count < 10,
           let moreId = InnerTubeParsing.songsShelfMoreBrowseId(in: root),
           let moreRoot = try? await browseRoot(browseId: moreId) {
            let moreSongs = InnerTubeParsing.parseTracks(in: moreRoot)
            if !moreSongs.isEmpty {
                detail = ArtistDetail(
                    id: detail.id,
                    name: detail.name,
                    thumbnails: detail.thumbnails,
                    subscribers: detail.subscribers,
                    topSongs: moreSongs,
                    albums: detail.albums,
                    singles: detail.singles,
                    playlists: detail.playlists
                )
            }
        }
        return detail
    }

    func album(id: String) async throws -> Album {
        let normalized = (id.hasPrefix("PL") || id.hasPrefix("OLAK")) ? "VL" + id : id
        let root = try await browseRoot(browseId: normalized)
        return InnerTubeParsing.parseAlbum(id: id, in: root)
    }

    func playlist(id: String) async throws -> Playlist {
        // Moods-category ids are encoded as "browseId:params" by
        // `InnerTubeParsing.parseGenres`; browse them directly.
        if let colon = id.firstIndex(of: ":") {
            let browseId = String(id[..<colon])
            let params = String(id[id.index(after: colon)...])
            let root = try await browseRoot(browseId: browseId, params: params)
            return InnerTubeParsing.parsePlaylist(id: id, in: root)
        }
        let browseId: String
        if id.hasPrefix("VL") || id.hasPrefix("RDCLAK") || id.hasPrefix("FE")
            || id.hasPrefix("MPRE") || id.hasPrefix("UC") {
            browseId = id
        } else {
            browseId = "VL" + id
        }
        let root = try await browseRoot(browseId: browseId)
        var playlist = InnerTubeParsing.parsePlaylist(id: id, in: root)
        if playlist.tracks.isEmpty {
            // The `next` endpoint serves playlist panels when `browse`
            // returns no tracks (radio/mix ids and the Liked list).
            let nextId = id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
            if let nextRoot = try? await nextRoot(videoId: nil, playlistId: nextId) {
                let tracks = InnerTubeParsing.parseRadioTracks(in: nextRoot)
                if !tracks.isEmpty {
                    playlist = Playlist(
                        id: playlist.id,
                        title: playlist.title,
                        author: playlist.author,
                        thumbnails: playlist.thumbnails,
                        tracks: tracks,
                        description: playlist.description
                    )
                }
            }
        }
        return playlist
    }

    // MARK: - Protocol: queue / player

    func next(videoId: String, playlistId: String?) async throws -> [Track] {
        let root = try await nextRoot(
            videoId: videoId,
            playlistId: playlistId ?? "RDAMVM" + videoId,
            params: playlistId == nil ? "wAEB" : nil
        )
        return InnerTubeParsing.parseRadioTracks(in: root)
    }

    func player(videoId: String) async throws -> StreamInfo {
        try await resolver().resolve(videoId: videoId)
    }

    // MARK: - Protocol: like

    func like(videoId: String, status: LikeStatus) async throws {
        guard YouTubeSession.shared.isLoggedIn else { throw InnerTubeError.notLoggedIn }
        let endpoint: String
        switch status {
        case .liked: endpoint = "like/like"
        case .disliked: endpoint = "like/dislike"
        case .none: endpoint = "like/removelike"
        }
        let config = await webConfig()
        let visitorData = await currentVisitorData()
        let body: [String: Any] = [
            "context": makeContext(
                clientName: "WEB_REMIX",
                clientVersion: config.clientVersion,
                visitorData: visitorData,
                authenticated: true
            ),
            "target": ["videoId": videoId],
        ]
        _ = try await postJSON(
            endpoint: endpoint,
            body: body,
            clientName: "WEB_REMIX",
            clientVersion: config.clientVersion,
            authenticated: true
        )
    }

    // MARK: - Protocol: charts / new releases / genres

    func charts(country: String) async throws -> [FeedSection] {
        let root = try await browseRoot(browseId: "FEmusic_charts", gl: country)
        return InnerTubeParsing.parseFeedSections(in: root)
    }

    func newReleases() async throws -> [AlbumRef] {
        let root = try await browseRoot(browseId: "FEmusic_new_releases_albums")
        return InnerTubeParsing.parseEntities(in: root)
            .filter { $0.kind == .album }
            .map { AlbumRef(id: $0.id, title: $0.name, thumbnails: $0.thumbnails) }
    }

    func genres() async throws -> [FeedSection] {
        let root = try await browseRoot(browseId: "FEmusic_moods_and_genres")
        return InnerTubeParsing.parseGenres(in: root)
    }

    // MARK: - Web config bootstrap

    /// The current web config, bootstrapped from the homepage when needed.
    /// A config whose visitor data is only the synthetic placeholder is
    /// usable but not final; it is refreshed once the retry cooldown
    /// elapses. Mirrors Android `getWebConfig`.
    func webConfig() async -> InnerTubeWebConfig {
        if let cached = cachedConfig, InnerTubeConstants.isValidVisitorData(cached.visitorData) {
            return cached
        }
        if let last = lastConfigFetch, Date().timeIntervalSince(last) < 60, let cached = cachedConfig {
            return cached
        }
        lastConfigFetch = Date()
        if let fetched = try? await fetchWebConfig() {
            cachedConfig = fetched
            return fetched
        }
        let fallback = cachedConfig ?? InnerTubeWebConfig(
            apiKey: InnerTubeConstants.fallbackAPIKey,
            clientVersion: InnerTubeConstants.fallbackClientVersion,
            visitorData: nil
        )
        cachedConfig = fallback
        return fallback
    }

    private func fetchWebConfig() async throws -> InnerTubeWebConfig {
        guard let url = URL(string: InnerTubeConstants.musicOrigin + "/") else {
            throw InnerTubeError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue(InnerTubeConstants.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(InnerTubeConstants.consentCookie, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw InnerTubeError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let visitorData = findConfig(html, key: "VISITOR_DATA")
            ?? findConfig(html, key: "EOM_VISITOR_DATA")
        return InnerTubeWebConfig(
            apiKey: findConfig(html, key: "INNERTUBE_API_KEY") ?? InnerTubeConstants.fallbackAPIKey,
            clientVersion: findConfig(html, key: "INNERTUBE_CONTEXT_CLIENT_VERSION")
                ?? InnerTubeConstants.fallbackClientVersion,
            visitorData: visitorData.flatMap { InnerTubeConstants.isValidVisitorData($0) ? $0 : nil }
        )
    }

    /// Finds a `"KEY": "value"` pair in homepage HTML, handling both
    /// plain JSON and the escaped form embedded in JS strings. Mirrors
    /// Android `findConfig`.
    private func findConfig(_ html: String, key: String) -> String? {
        let patterns = [
            "\"" + key + "\"\\s*:\\s*\"([^\"]+)\"",
            "\\\\\"" + key + "\\\\\"\\\\s*:\\\\s*\\\\\"([^\\\\\"]+)\\\\\"",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html) else {
                continue
            }
            let value = String(html[range])
                .replacingOccurrences(of: "\\u003d", with: "=")
                .replacingOccurrences(of: "\\x3d", with: "=")
                .replacingOccurrences(of: "\\/", with: "/")
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// The visitor data actually sent with requests, from the poToken
    /// generator first, then the settings store, then the session cookie
    /// store, then a fresh fetch.
    func currentVisitorData() async -> String? {
        if let visitor = PoTokenGenerator.shared.visitorData,
           InnerTubeConstants.isValidVisitorData(visitor) {
            return visitor
        }
        if let visitor = SettingsStore.shared.visitorData,
           InnerTubeConstants.isValidVisitorData(visitor) {
            return visitor
        }
        if let visitor = YouTubeSession.shared.visitorData,
           InnerTubeConstants.isValidVisitorData(visitor) {
            return visitor
        }
        return await PoTokenGenerator.shared.ensureVisitorData()
    }

    // MARK: - Request context

    /// The `context` object every InnerTube request carries. Mirrors
    /// Android `context()`.
    func makeContext(
        clientName: String,
        clientVersion: String,
        visitorData: String?,
        authenticated: Bool,
        hl: String? = nil,
        gl: String? = nil
    ) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": clientName,
            "clientVersion": clientVersion,
            "hl": hl ?? Self.localeLanguage(),
            "gl": gl ?? Self.localeRegion(),
        ]
        if let visitorData, InnerTubeConstants.isValidVisitorData(visitorData) {
            client["visitorData"] = visitorData
        }
        var context: [String: Any] = ["client": client]
        if authenticated {
            context["user"] = ["lockedSafetyMode": false]
        }
        return context
    }

    private static func localeLanguage() -> String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    private static func localeRegion() -> String {
        Locale.current.region?.identifier ?? "US"
    }

    // MARK: - Transport

    /// One InnerTube POST. Retries once with a clean (en/US, signed-out)
    /// context after a 400, mirroring the Android `post` helper.
    func postJSON(
        endpoint: String,
        body: [String: Any],
        clientName: String = "WEB_REMIX",
        clientVersion: String? = nil,
        authenticated: Bool = false,
        origin: String = InnerTubeConstants.musicOrigin,
        referer: String? = nil,
        apiKey: String? = nil,
        apiBase: String? = nil
    ) async throws -> JSONValue {
        let config = await webConfig()
        let version = clientVersion ?? config.clientVersion
        let key = apiKey ?? config.apiKey
        let base = apiBase ?? InnerTubeConstants.musicAPI
        let visitorData = await currentVisitorData()
        let effectiveReferer = referer ?? origin + "/"

        func buildRequest(cleanContext: Bool) -> URLRequest? {
            guard let url = URL(string: "\(base)/\(endpoint)?key=\(key)&prettyPrint=false") else {
                return nil
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(InnerTubeConstants.webUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue(origin, forHTTPHeaderField: "X-Origin")
            request.setValue(effectiveReferer, forHTTPHeaderField: "Referer")
            request.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
            request.setValue(InnerTubeConstants.clientIDs[clientName] ?? clientName, forHTTPHeaderField: "X-YouTube-Client-Name")
            request.setValue(version, forHTTPHeaderField: "X-YouTube-Client-Version")
            let (hl, gl) = cleanContext ? ("en", "US") : (Self.localeLanguage(), Self.localeRegion())
            request.setValue("\(hl)-\(gl),\(hl);q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            if let visitorData, InnerTubeConstants.isValidVisitorData(visitorData), !cleanContext {
                request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
            }
            if authenticated, let authorization = YouTubeSession.shared.sapisidHash() {
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
            var finalBody = body
            if cleanContext,
               var context = finalBody["context"] as? [String: Any],
               var client = context["client"] as? [String: Any] {
                client["hl"] = "en"
                client["gl"] = "US"
                context["client"] = client
                context.removeValue(forKey: "user")
                finalBody["context"] = context
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: finalBody)
            return request
        }

        guard let request = buildRequest(cleanContext: false) else {
            throw InnerTubeError.invalidResponse
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw InnerTubeError.network }
        if http.statusCode == 400, let retry = buildRequest(cleanContext: true) {
            let (retryData, retryResponse) = try await session.data(for: retry)
            guard let retryHttp = retryResponse as? HTTPURLResponse,
                  (200...299).contains(retryHttp.statusCode) else {
                throw InnerTubeError.http((retryResponse as? HTTPURLResponse)?.statusCode ?? http.statusCode)
            }
            return try JSONValue(data: retryData)
        }
        guard (200...299).contains(http.statusCode) else {
            throw InnerTubeError.http(http.statusCode)
        }
        return try JSONValue(data: data)
    }

    // MARK: - Browse / next helpers

    private func browseRoot(browseId: String, authenticated: Bool? = nil, params: String? = nil, gl: String? = nil) async throws -> JSONValue {
        let isAuth = authenticated ?? YouTubeSession.shared.isLoggedIn
        do {
            return try await browseOnce(browseId: browseId, authenticated: isAuth, params: params, gl: gl)
        } catch let error as InnerTubeError {
            // A 400/403 usually means the bootstrapped config went stale;
            // drop it and retry once with a fresh one.
            if case .http(let code) = error, code == 400 || code == 403 {
                cachedConfig = nil
                return try await browseOnce(browseId: browseId, authenticated: isAuth, params: params, gl: gl)
            }
            throw error
        }
    }

    private func browseOnce(browseId: String, authenticated: Bool, params: String?, gl: String?) async throws -> JSONValue {
        let config = await webConfig()
        let visitorData = await currentVisitorData()
        var body: [String: Any] = [
            "context": makeContext(
                clientName: "WEB_REMIX",
                clientVersion: config.clientVersion,
                visitorData: visitorData,
                authenticated: authenticated,
                gl: gl
            ),
            "browseId": browseId,
        ]
        if let params { body["params"] = params }
        return try await postJSON(
            endpoint: "browse",
            body: body,
            clientName: "WEB_REMIX",
            clientVersion: config.clientVersion,
            authenticated: authenticated
        )
    }

    private func nextRoot(videoId: String?, playlistId: String?, params: String? = nil) async throws -> JSONValue {
        let config = await webConfig()
        let visitorData = await currentVisitorData()
        var body: [String: Any] = [
            "context": makeContext(
                clientName: "WEB_REMIX",
                clientVersion: config.clientVersion,
                visitorData: visitorData,
                authenticated: YouTubeSession.shared.isLoggedIn
            ),
            "isAudioOnly": true,
        ]
        if let videoId { body["videoId"] = videoId }
        if let playlistId { body["playlistId"] = playlistId }
        if let params { body["params"] = params }
        return try await postJSON(
            endpoint: "next",
            body: body,
            clientName: "WEB_REMIX",
            clientVersion: config.clientVersion,
            authenticated: YouTubeSession.shared.isLoggedIn
        )
    }

    // MARK: - Search helpers

    private func searchOnce(query: String, params: String?) async -> JSONValue? {
        let config = await webConfig()
        let visitorData = await currentVisitorData()
        var body: [String: Any] = [
            "context": makeContext(
                clientName: "WEB_REMIX",
                clientVersion: config.clientVersion,
                visitorData: visitorData,
                authenticated: false
            ),
            "query": query,
        ]
        if let params { body["params"] = params }
        return try? await postJSON(
            endpoint: "search",
            body: body,
            clientName: "WEB_REMIX",
            clientVersion: config.clientVersion
        )
    }

    /// The standard YouTube WEB client as a fallback when WEB_REMIX is
    /// blocked on this network, mirroring the Android search fallbacks.
    private func webFallbackSearch(query: String, params: String?) async -> JSONValue? {
        var body: [String: Any] = [
            "context": makeContext(
                clientName: "WEB",
                clientVersion: InnerTubeConstants.webClientVersion,
                visitorData: nil,
                authenticated: false
            ),
            "query": query,
        ]
        if let params { body["params"] = params }
        return try? await postJSON(
            endpoint: "search",
            body: body,
            clientName: "WEB",
            clientVersion: InnerTubeConstants.webClientVersion,
            origin: InnerTubeConstants.youtubeOrigin,
            referer: InnerTubeConstants.youtubeOrigin + "/",
            apiKey: InnerTubeConstants.webAPIKey,
            apiBase: InnerTubeConstants.youtubeAPI
        )
    }

    private func searchSongs(_ query: String) async -> [Track] {
        if let root = await searchOnce(query: query, params: Self.songSearchFilter) {
            let tracks = InnerTubeParsing.parseTracks(in: root)
            if !tracks.isEmpty { return tracks }
        }
        if let root = await searchOnce(query: query, params: nil) {
            let tracks = InnerTubeParsing.parseTracks(in: root)
            if !tracks.isEmpty { return tracks }
        }
        if let root = await webFallbackSearch(query: query, params: nil) {
            return InnerTubeParsing.parseTracks(in: root)
        }
        return []
    }

    private func searchEntities(_ query: String, kind: InnerTubeParsing.EntityKind) async -> [InnerTubeParsing.ParsedEntity] {
        let filter = kind == .artist ? Self.artistSearchFilter : Self.albumSearchFilter
        if let root = await searchOnce(query: query, params: filter) {
            let entities = InnerTubeParsing.parseEntities(in: root).filter { $0.kind == kind }
            if !entities.isEmpty { return entities }
        }
        if let root = await searchOnce(query: query, params: nil) {
            let entities = InnerTubeParsing.parseEntities(in: root).filter { $0.kind == kind }
            if !entities.isEmpty { return entities }
        }
        if let root = await webFallbackSearch(query: query, params: nil) {
            return InnerTubeParsing.parseEntities(in: root).filter { $0.kind == kind }
        }
        return []
    }

    private func searchPlaylists(_ query: String) async -> [PlaylistRef] {
        let toRef: (InnerTubeParsing.ParsedEntity) -> PlaylistRef = { entity in
            let playlistId = entity.id.hasPrefix("VL") ? String(entity.id.dropFirst(2)) : entity.id
            return PlaylistRef(id: playlistId, title: entity.name, author: entity.artist, thumbnails: entity.thumbnails)
        }
        if let root = await searchOnce(query: query, params: Self.playlistSearchFilter) {
            let items = InnerTubeParsing.parseEntities(in: root).filter { $0.kind == .playlist }
            if !items.isEmpty { return items.map(toRef) }
        }
        if let root = await webFallbackSearch(query: query, params: Self.playlistSearchFilter) {
            return InnerTubeParsing.parseEntities(in: root).filter { $0.kind == .playlist }.map(toRef)
        }
        return []
    }

    private func searchVideos(_ query: String) async -> [Track] {
        if let root = await searchOnce(query: query, params: Self.videoSearchFilter) {
            let videos = InnerTubeParsing.parseVideoTracks(in: root)
            if !videos.isEmpty { return videos }
            let tracks = InnerTubeParsing.parseTracks(in: root)
            if !tracks.isEmpty { return tracks.map(Self.withVideoFlag) }
        }
        return []
    }

    private static func withVideoFlag(_ track: Track) -> Track {
        Track(
            id: track.id,
            title: track.title,
            artists: track.artists,
            album: track.album,
            durationSeconds: track.durationSeconds,
            thumbnails: track.thumbnails,
            isVideo: true,
            explicit: track.explicit,
            likeStatus: track.likeStatus,
            playCount: track.playCount
        )
    }
}
