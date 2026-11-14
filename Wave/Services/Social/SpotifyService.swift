import Foundation

// MARK: - Spotify import
//
// Imports a Spotify playlist and matches every row to a playable YouTube
// Music track (the same approach as the Android app's
// `SpotifyPlaylistImporter.matchRowsToTracks`, which searches InnerTube for
// "title artist" and takes the best match, bounded to 4 concurrent searches).
//
// Two sources, in order:
//  1. Spotify Web API with the client id/secret from Settings
//     (client-credentials flow: `POST accounts.spotify.com/api/token`, then
//     `GET api.spotify.com/v1/playlists/{id}` + `/tracks` with pagination).
//     No user login is involved, so this works for public playlists only.
//  2. Public embed page fallback (`open.spotify.com/embed/playlist/{id}`,
//     `__NEXT_DATA__` JSON) when no client credentials are configured —
//     same fallback the Android app uses, capped at ~100 tracks.
//
// Liked Songs (`/v1/me/tracks`) needs a *user* access token, which the
// client-credentials flow cannot mint, so `likedSongs()` throws
// `SpotifyError.userAuthorizationRequired` until a user-OAuth login is added.

enum SpotifyError: Error, LocalizedError {
    case notConfigured
    case invalidURL
    case httpStatus(Int)
    case userAuthorizationRequired(String)
    case noTracks

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add a Spotify client id and secret in Settings, or paste a public playlist link"
        case .invalidURL:
            return "That does not look like a Spotify playlist link"
        case .httpStatus(let code):
            return "Spotify returned HTTP \(code)"
        case .userAuthorizationRequired(let message):
            return message
        case .noTracks:
            return "No tracks could be read from that playlist"
        }
    }
}

final class SpotifyService {
    static let shared = SpotifyService()

    private static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    private static let apiBase = "https://api.spotify.com/v1"
    private static let embedBase = "https://open.spotify.com/embed/playlist/"
    private static let desktopUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    private static let matchConcurrency = 4

    private let settings: SettingsStore
    private var cachedToken: (token: String, expiresAt: Date)?

    init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    /// Imports the playlist at the given link/URI/id and returns it with its
    /// tracks matched to playable YouTube Music tracks.
    func importPlaylist(url: String) async throws -> Playlist {
        let id = try await extractId(from: url)
        let rows: [SpotifyRow]
        var title = "Spotify Playlist"
        var author: String?
        var thumbnails: [Thumbnail] = []

        if !settings.spotifyClientId.isEmpty, !settings.spotifyClientSecret.isEmpty {
            let fetched = try await fetchViaWebAPI(id: id)
            rows = fetched.rows
            title = fetched.title
            author = fetched.author
            thumbnails = fetched.thumbnails
        } else {
            let fetched = try await fetchViaEmbed(id: id)
            rows = fetched.rows
            title = fetched.title
        }

        guard !rows.isEmpty else { throw SpotifyError.noTracks }
        let tracks = await matchRows(rows)
        return Playlist(
            id: "spotify:\(id)",
            title: title,
            author: author,
            thumbnails: thumbnails,
            tracks: tracks
        )
    }

    /// The user's Liked Songs. Requires user authorisation (OAuth), which
    /// this build does not have — the client-credentials token cannot call
    /// `/v1/me/tracks`.
    func likedSongs() async throws -> [Track] {
        throw SpotifyError.userAuthorizationRequired(
            "Liked Songs needs a Spotify account login. Connect your Spotify account in Settings first."
        )
    }

    // MARK: - Playlist id extraction

    func extractId(from input: String) async throws -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("spotify.link") {
            // Resolve the short link to its real URL (redirects followed).
            guard let shortURL = URL(string: text) else { throw SpotifyError.invalidURL }
            var request = URLRequest(url: shortURL)
            request.httpMethod = "HEAD"
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let finalURL = response.url {
                text = finalURL.absoluteString
            }
        }
        if text.hasPrefix("spotify:playlist:") {
            return String(text.dropFirst("spotify:playlist:".count))
        }
        if let range = text.range(of: "playlist/") {
            let tail = text[range.upperBound...]
            let id = tail.split(whereSeparator: { "?#/".contains($0) }).first.map(String.init) ?? ""
            guard !id.isEmpty else { throw SpotifyError.invalidURL }
            return id
        }
        // A bare playlist id (22 base62 characters).
        let bare = text
        guard !bare.isEmpty,
              bare.count == 22,
              bare.allSatisfy({ $0.isLetter || $0.isNumber })
        else { throw SpotifyError.invalidURL }
        return bare
    }

    // MARK: - Web API (client credentials)

    private struct FetchedPlaylist {
        var title: String
        var author: String?
        var thumbnails: [Thumbnail]
        var rows: [SpotifyRow]
    }

    private struct SpotifyRow {
        var title: String
        var artist: String
        var album: String?
    }

    private func accessToken() async throws -> String {
        if let cached = cachedToken, cached.expiresAt > Date() {
            return cached.token
        }
        let credentials = "\(settings.spotifyClientId):\(settings.spotifyClientSecret)"
        guard let credentialData = credentials.data(using: .utf8) else {
            throw SpotifyError.notConfigured
        }
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("Basic \(credentialData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=client_credentials".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpotifyError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = json["access_token"] as? String
        else { throw SpotifyError.notConfigured }
        let expiresIn = (json["expires_in"] as? Double) ?? 3_600
        cachedToken = (token, Date().addingTimeInterval(expiresIn - 60))
        return token
    }

    private func webAPIGet(path: String) async throws -> [String: Any] {
        let token = try await accessToken()
        guard let url = URL(string: Self.apiBase + path) else { throw SpotifyError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpotifyError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpotifyError.httpStatus(200)
        }
        return json
    }

    private func fetchViaWebAPI(id: String) async throws -> FetchedPlaylist {
        let meta = try await webAPIGet(path: "/playlists/\(id)?fields=name,owner(display_name),images")
        let title = meta["name"] as? String ?? "Spotify Playlist"
        let author = (meta["owner"] as? [String: Any])?["display_name"] as? String
        let thumbnails: [Thumbnail] = ((meta["images"] as? [[String: Any]]) ?? []).compactMap { image in
            guard let urlString = image["url"] as? String, let url = URL(string: urlString) else { return nil }
            return Thumbnail(url: url, width: image["width"] as? Int ?? 0, height: image["height"] as? Int ?? 0)
        }

        var rows: [SpotifyRow] = []
        var offset = 0
        while true {
            let page = try await webAPIGet(
                path: "/playlists/\(id)/tracks?limit=100&offset=\(offset)&fields=items(track(name,artists(name),album(name))),total,next"
            )
            let items = page["items"] as? [[String: Any]] ?? []
            for item in items {
                guard let track = item["track"] as? [String: Any],
                      let name = track["name"] as? String, !name.isEmpty
                else { continue }
                let artists = ((track["artists"] as? [[String: Any]]) ?? [])
                    .compactMap { $0["name"] as? String }
                    .joined(separator: ", ")
                let album = (track["album"] as? [String: Any])?["name"] as? String
                rows.append(SpotifyRow(title: name, artist: artists, album: album))
            }
            let total = page["total"] as? Int ?? rows.count
            offset += items.count
            let hasNextPage = page["next"] is String
            if items.isEmpty || offset >= total || !hasNextPage { break }
        }
        return FetchedPlaylist(title: title, author: author, thumbnails: thumbnails, rows: rows)
    }

    // MARK: - Embed page fallback (no credentials)

    private func fetchViaEmbed(id: String) async throws -> FetchedPlaylist {
        guard let url = URL(string: Self.embedBase + id) else { throw SpotifyError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpotifyError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let html = String(data: data, encoding: .utf8) else { throw SpotifyError.noTracks }
        return parseEmbedPage(html: html)
    }

    /// Pure parser: embed HTML in, playlist rows out. Never throws — an
    /// unreadable page yields an empty row list.
    func parseEmbedPage(html: String, fallbackTitle: String = "Spotify Playlist") -> FetchedPlaylist {
        let pattern = "<script[^>]*\\bid=[\"']__NEXT_DATA__[\"'][^>]*>(.*?)</script>"
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            let payloadRange = Range(match.range(at: 1), in: html)
        else {
            return FetchedPlaylist(title: fallbackTitle, author: nil, thumbnails: [], rows: [])
        }
        let payload = unescapeHTML(String(html[payloadRange]))
        guard
            let data = payload.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
        else {
            return FetchedPlaylist(title: fallbackTitle, author: nil, thumbnails: [], rows: [])
        }

        var title: String?
        var rows: [SpotifyRow] = []
        var seenURIs: Set<String> = []
        walkJSON(root) { object in
            guard let uri = object["uri"] as? String,
                  let name = object["title"] as? String
            else { return }
            if uri.hasPrefix("spotify:playlist:") {
                if title == nil { title = name.trimmingCharacters(in: .whitespaces) }
            } else if uri.hasPrefix("spotify:track:") {
                let trackTitle = name.trimmingCharacters(in: .whitespaces)
                guard !trackTitle.isEmpty, seenURIs.insert(uri).inserted else { return }
                let artist = (object["subtitle"] as? String ?? "")
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                rows.append(SpotifyRow(title: trackTitle, artist: artist, album: nil))
            }
        }
        let resolvedTitle = (title?.isEmpty == false) ? title! : fallbackTitle
        return FetchedPlaylist(title: resolvedTitle, author: nil, thumbnails: [], rows: rows)
    }

    private func walkJSON(_ value: Any, visit: ([String: Any]) -> Void) {
        var pending: [Any] = [value]
        while let current = pending.popLast() {
            if let object = current as? [String: Any] {
                visit(object)
                pending.append(contentsOf: object.values)
            } else if let array = current as? [Any] {
                pending.append(contentsOf: array)
            }
        }
    }

    private func unescapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Matching rows to playable tracks

    private func matchRows(_ rows: [SpotifyRow]) async -> [Track] {
        var matched: [Track] = []
        // Bounded fan-out: 4 concurrent InnerTube searches at a time.
        for chunkStart in stride(from: 0, to: rows.count, by: Self.matchConcurrency) {
            let chunk = Array(rows[chunkStart..<min(chunkStart + Self.matchConcurrency, rows.count)])
            let chunkMatches = await withTaskGroup(of: Track?.self) { group in
                for row in chunk {
                    group.addTask { await Self.matchRow(row) }
                }
                var found: [Track] = []
                for await track in group {
                    if let track { found.append(track) }
                }
                return found
            }
            matched.append(contentsOf: chunkMatches)
        }
        return matched
    }

    /// Matches one Spotify row to a playable YouTube Music track via an
    /// InnerTube search ("title artist", falling back to the title alone).
    /// Static so the matching task group does not capture the service.
    private static func matchRow(_ row: SpotifyRow) async -> Track? {
        let innerTube = InnerTubeClient.shared
        if let results = try? await innerTube.search(query: "\(row.title) \(row.artist)"),
           let first = results.songs.first {
            return first
        }
        if let results = try? await innerTube.search(query: row.title),
           let first = results.songs.first {
            return first
        }
        return nil
    }
}
