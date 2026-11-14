import Foundation

// MARK: - Flexible JSON value
//
// InnerTube responses are deeply nested renderer trees whose shapes vary
// between endpoints and over time. Rather than a forest of Codable structs
// that throw away a whole response when one field changes shape, parsing
// works on this small untyped value: every accessor is optional, so a
// missing field degrades one item instead of failing the whole call.

enum JSONValue: Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(data: Data) throws {
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        self.init(raw)
    }

    init(_ raw: Any) {
        switch raw {
        case let dict as [String: Any]:
            self = .object(dict.mapValues { JSONValue($0) })
        case let arr as [Any]:
            self = .array(arr.map { JSONValue($0) })
        case let str as String:
            self = .string(str)
        case let num as NSNumber:
            // JSON booleans arrive as NSNumber with objCType "c".
            if String(cString: num.objCType) == "c" {
                self = .bool(num.boolValue)
            } else {
                self = .number(num.doubleValue)
            }
        default:
            self = .null
        }
    }

    var asObject: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var asArray: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var asString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var asInt: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    func object(_ key: String) -> JSONValue? {
        asObject?[key]
    }

    func array(_ key: String) -> [JSONValue]? {
        object(key)?.asArray
    }

    func string(_ key: String) -> String? {
        object(key)?.asString
    }

    func int(_ key: String) -> Int? {
        object(key)?.asInt
    }

    func bool(_ key: String) -> Bool? {
        guard case .bool(let value) = object(key) ?? .null else { return nil }
        return value
    }

    /// The text of a YouTube renderer: `runs` joined, `simpleText`, or a
    /// plain string. Mirrors the Android `youtubeText` helper.
    var text: String? {
        switch self {
        case .string(let value):
            return value
        case .object:
            if let runs = array("runs") {
                let joined = runs.compactMap { $0.string("text") }.joined()
                if !joined.isEmpty { return joined }
            }
            return string("simpleText")
        default:
            return nil
        }
    }

    /// Recursively collects every object stored under `key` anywhere below
    /// this value, in document order. Mirrors Android `collectObjects`.
    func collectObjects(key: String, into output: inout [JSONValue]) {
        switch self {
        case .object(let dict):
            for (name, child) in dict {
                if name == key, case .object = child {
                    output.append(child)
                }
                child.collectObjects(key: key, into: &output)
            }
        case .array(let items):
            for child in items {
                child.collectObjects(key: key, into: &output)
            }
        default:
            break
        }
    }

    /// Recursively collects every array stored under `key` anywhere below
    /// this value, in document order.
    func collectArrays(key: String, into output: inout [[JSONValue]]) {
        switch self {
        case .object(let dict):
            for (name, child) in dict {
                if name == key, let array = child.asArray {
                    output.append(array)
                }
                child.collectArrays(key: key, into: &output)
            }
        case .array(let items):
            for child in items {
                child.collectArrays(key: key, into: &output)
            }
        default:
            break
        }
    }

    /// First string found under `key` anywhere below this value.
    /// Mirrors Android `findString`.
    func findString(_ key: String) -> String? {
        switch self {
        case .object(let dict):
            if let value = dict[key], case .string(let text) = value {
                return text
            }
            for child in dict.values {
                if let found = child.findString(key) { return found }
            }
            return nil
        case .array(let items):
            for child in items {
                if let found = child.findString(key) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    /// First object stored under `accountName` (with a `simpleText` child),
    /// found anywhere below this value. Used for the login display name.
    func findAccountName() -> String? {
        switch self {
        case .object(let dict):
            if let account = dict["accountName"] {
                if let text = account.text { return text }
                if let simple = account.string("simpleText") { return simple }
            }
            for child in dict.values {
                if let found = child.findAccountName() { return found }
            }
            return nil
        case .array(let items):
            for child in items {
                if let found = child.findAccountName() { return found }
            }
            return nil
        default:
            return nil
        }
    }
}

private extension String {
    /// Trimmed string, or nil when blank.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - InnerTube parsing
//
// Ports of the Android parsers in `InnerTubeMusicApiParsers.kt`. Every
// function returns nil / an empty array when its input is missing or
// malformed, never throws: one bad renderer must not lose the shelf.

enum InnerTubeParsing {

    // MARK: - Scalar helpers

    /// "3:24" -> 204, "1:02:03" -> 3723. Mirrors Android `parseDuration`.
    static func parseDuration(_ value: String) -> Int? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .compactMap { Int($0) }
        guard parts.count >= 2 && parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Google-hosted artwork URLs carry a size suffix after the last `=`;
    /// rewrite it to a 1200px render. Mirrors Android
    /// `String.highResolutionArtwork()`.
    static func highResolutionArtwork(_ url: String) -> String {
        let withScheme = url.hasPrefix("//") ? "https:" + url : url
        if (withScheme.contains("googleusercontent.com") || withScheme.contains("ggpht.com")),
           withScheme.contains("=") {
            return withScheme.components(separatedBy: "=").dropLast().joined(separator: "=")
                + "=w1200-h1200-l90-rj"
        }
        return withScheme
    }

    /// A run text is probably an artist name when it is not a separator, a
    /// kind label, a duration, a year, or a play-count stat. Mirrors Android
    /// `String.isLikelyArtistDetail()`.
    static func isLikelyArtist(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "•", text != "·", text != "Song", text != "Video" else { return false }
        let lower = text.lowercased()
        if lower == "album" || lower == "single" || lower == "ep" || lower == "playlist" { return false }
        if parseDuration(text) != nil { return false }
        if text.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil { return false }
        let statWords = [" view", " views", " song", " play", " plays", " stream", " track",
                         " listen", " subscrib", " follow", " monthly", " fan", " scrobbl"]
        if statWords.contains(where: { lower.contains($0) }) { return false }
        if let first = text.first, first.isNumber,
           ["listen", "subscrib", "follow", "monthly", "play", "view", "stream", "scrobbl"]
            .contains(where: { lower.contains($0) }) {
            return false
        }
        return true
    }

    // MARK: - Thumbnails

    /// All thumbnails from the first non-empty `thumbnails` array found
    /// under the renderer's `thumbnail` / `thumbnailRenderer` node, falling
    /// back to anywhere in the renderer. Mirrors Android
    /// `extractThumbnailsUrl`, extended to keep width/height.
    static func thumbnails(in renderer: JSONValue) -> [Thumbnail] {
        var found: [[JSONValue]] = []
        let scope = renderer.object("thumbnail") ?? renderer.object("thumbnailRenderer") ?? renderer
        scope.collectArrays(key: "thumbnails", into: &found)
        guard let best = found.first(where: { !$0.isEmpty }) else { return [] }
        return best.compactMap { item in
            guard let urlString = item.string("url") else { return nil }
            return Thumbnail(
                url: URL(string: highResolutionArtwork(urlString)),
                width: item.int("width") ?? 0,
                height: item.int("height") ?? 0
            )
        }
    }

    // MARK: - Navigation

    /// The video id a renderer plays when tapped. Mirrors Android
    /// `directWatchVideoId`.
    static func directWatchVideoId(in renderer: JSONValue) -> String? {
        if let id = renderer.object("playlistItemData")?.string("videoId") { return id }
        if let id = renderer.object("navigationEndpoint")?.object("watchEndpoint")?.string("videoId") { return id }

        if let overlay = renderer.object("overlay") ?? renderer.object("thumbnailOverlay"),
           let musicItem = overlay.object("musicItemThumbnailOverlayRenderer"),
           let content = musicItem.object("content"),
           let playButton = content.object("musicPlayButtonRenderer"),
           let playEndpoint = playButton.object("playNavigationEndpoint"),
           let watchEndpoint = playEndpoint.object("watchEndpoint"),
           let id = watchEndpoint.string("videoId") {
            return id
        }

        if let id = renderer.object("onTap")?.object("watchEndpoint")?.string("videoId") { return id }

        if let columns = renderer.array("flexColumns"),
           let firstColumn = columns.first,
           let flexRenderer = firstColumn.object("musicResponsiveListItemFlexColumnRenderer"),
           let text = flexRenderer.object("text"),
           let runs = text.array("runs"),
           let firstRun = runs.first,
           let navigation = firstRun.object("navigationEndpoint"),
           let watch = navigation.object("watchEndpoint"),
           let id = watch.string("videoId") {
            return id
        }

        return renderer.object("doubleTapCommand")?.object("watchEndpoint")?.string("videoId")
    }

    /// True when the row is a "suggestion" (add-to-playlist) row rather than
    /// a real track. Mirrors Android `isSuggestionItem`.
    static func isSuggestionItem(_ renderer: JSONValue) -> Bool {
        var endpoints: [JSONValue] = []
        renderer.collectObjects(key: "playlistEditEndpoint", into: &endpoints)
        guard !endpoints.isEmpty else { return false }
        var hasAdd = false
        var hasRemove = false
        for endpoint in endpoints {
            guard let actions = endpoint.array("actions") else { continue }
            for action in actions {
                let name = action.string("action") ?? ""
                if name.localizedCaseInsensitiveContains("ACTION_ADD") || name.localizedCaseInsensitiveContains("ADD_VIDEO") {
                    hasAdd = true
                }
                if name.localizedCaseInsensitiveContains("ACTION_REMOVE") || name.localizedCaseInsensitiveContains("REMOVE_VIDEO") {
                    hasRemove = true
                }
            }
        }
        return hasAdd && !hasRemove
    }

    // MARK: - Run helpers

    private static func at<T>(_ array: [T], _ index: Int) -> T? {
        array.indices.contains(index) ? array[index] : nil
    }

    /// Artists (UC browse ids) and album (MPRE browse id) from a list of
    /// subtitle runs, with the "first likely artist" fallback.
    static func artistAndAlbum(from runs: [JSONValue]) -> (artists: [ArtistRef], album: AlbumRef?) {
        var artists: [ArtistRef] = []
        var album: AlbumRef?
        for run in runs {
            guard let text = run.string("text")?.trimmedNonEmpty else { continue }
            let browseId = run.object("navigationEndpoint")?.object("browseEndpoint")?.string("browseId")
            if let browseId, browseId.hasPrefix("UC") {
                artists.append(ArtistRef(id: browseId, name: text))
            } else if let browseId, browseId.hasPrefix("MPRE") {
                album = AlbumRef(id: browseId, title: text)
            }
        }
        if artists.isEmpty {
            for run in runs {
                guard let text = run.string("text") else { continue }
                if isLikelyArtist(text) {
                    artists.append(ArtistRef(id: "", name: text))
                    break
                }
            }
        }
        if artists.isEmpty {
            artists = [ArtistRef(id: "", name: "Unknown artist")]
        }
        return (artists, album)
    }

    private static func duration(from runs: [JSONValue]) -> Int? {
        runs.compactMap { $0.string("text") }.compactMap(parseDuration).first
    }

    // MARK: - Track renderers

    /// `musicResponsiveListItemRenderer`. Mirrors Android `parseSong`.
    static func parseTrack(from renderer: JSONValue) -> Track? {
        guard !isSuggestionItem(renderer) else { return nil }
        guard let videoId = directWatchVideoId(in: renderer) ?? renderer.findString("videoId") else { return nil }
        let columns = renderer.array("flexColumns") ?? []
        func columnText(_ index: Int) -> JSONValue? {
            at(columns, index)?.object("musicResponsiveListItemFlexColumnRenderer")?.object("text")
        }
        let title = columnText(0)?.text?.trimmedNonEmpty
            ?? renderer.object("title")?.text?.trimmedNonEmpty
        guard let title else { return nil }

        var detailRuns: [JSONValue] = []
        for index in 1..<columns.count {
            if let runs = columnText(index)?.array("runs") { detailRuns += runs }
        }
        if let fixed = renderer.array("fixedColumns") {
            for column in fixed {
                if let runs = column.object("musicResponsiveListItemFixedColumnRenderer")?.object("text")?.array("runs") {
                    detailRuns += runs
                }
            }
        }
        if let subtitleRuns = renderer.object("subtitle")?.array("runs") {
            detailRuns += subtitleRuns
        }
        let (artists, album) = artistAndAlbum(from: detailRuns)
        let durationSeconds = duration(from: detailRuns)
            ?? renderer.string("lengthSeconds").flatMap(Int.init)
        return Track(
            id: videoId,
            title: title,
            artists: artists,
            album: album,
            durationSeconds: durationSeconds,
            thumbnails: thumbnails(in: renderer)
        )
    }

    /// `musicTwoRowItemRenderer` that plays a song. Mirrors Android
    /// `parseTwoRowSong`.
    static func parseTwoRowTrack(from renderer: JSONValue) -> Track? {
        let titleRuns = renderer.object("title")?.array("runs")
        let videoId: String?
        if let id = directWatchVideoId(in: renderer) {
            videoId = id
        } else if let runs = titleRuns,
                  let first = runs.first,
                  let navigation = first.object("navigationEndpoint"),
                  let endpoint = navigation.object("watchEndpoint"),
                  let id = endpoint.string("videoId") {
            videoId = id
        } else {
            videoId = nil
        }

        guard let videoId else { return nil }
        guard let title = titleRuns?.compactMap({ $0.string("text") }).joined().trimmedNonEmpty
            ?? renderer.object("title")?.string("simpleText")?.trimmedNonEmpty
        else { return nil }
        let details = renderer.object("subtitle")?.array("runs") ?? []
        let (artists, album) = artistAndAlbum(from: details)
        return Track(
            id: videoId,
            title: title,
            artists: artists,
            album: album,
            durationSeconds: duration(from: details),
            thumbnails: thumbnails(in: renderer)
        )
    }

    /// `musicCardShelfRenderer` top card. Mirrors Android
    /// `parseCardShelfSong`.
    static func parseCardShelfTrack(from renderer: JSONValue) -> Track? {
        guard let videoId = directWatchVideoId(in: renderer)
            ?? renderer.object("title")?.array("runs")?.first?.object("navigationEndpoint")?.object("watchEndpoint")?.string("videoId")
            ?? renderer.object("onTap")?.object("watchEndpoint")?.string("videoId")
            ?? renderer.findString("videoId")
        else { return nil }
        guard let title = renderer.object("title")?.text?.trimmedNonEmpty else { return nil }
        let subRuns = renderer.object("subtitle")?.array("runs") ?? []
        let (artists, album) = artistAndAlbum(from: subRuns)
        return Track(
            id: videoId,
            title: title,
            artists: artists,
            album: album,
            durationSeconds: duration(from: subRuns),
            thumbnails: thumbnails(in: renderer)
        )
    }

    /// `playlistVideoRenderer` (plain YouTube playlist rows). Mirrors
    /// Android `parsePlaylistVideoRenderer`.
    static func parsePlaylistVideoTrack(from renderer: JSONValue) -> Track? {
        guard let videoId = renderer.string("videoId") else { return nil }
        guard let title = renderer.object("title")?.text?.trimmedNonEmpty else { return nil }
        let artist = renderer.object("shortBylineText")?.array("runs")?.first?.string("text")
            ?? "Unknown artist"
        return Track(
            id: videoId,
            title: title,
            artists: [ArtistRef(id: "", name: artist)],
            durationSeconds: renderer.string("lengthSeconds").flatMap(Int.init),
            thumbnails: thumbnails(in: renderer)
        )
    }

    /// `playlistPanelVideoRenderer` (queue / radio rows). Mirrors Android
    /// `parsePlaylistPanelSong`.
    static func parsePlaylistPanelTrack(from renderer: JSONValue) -> Track? {
        guard renderer.object("unplayableText") == nil else { return nil }
        guard let videoId = renderer.string("videoId")
            ?? renderer.object("navigationEndpoint")?.object("watchEndpoint")?.string("videoId")
        else { return nil }
        guard let title = renderer.object("title")?.text?.trimmedNonEmpty else { return nil }
        let detailRuns: [JSONValue]
        if let long = renderer.object("longBylineText")?.array("runs") {
            detailRuns = long
        } else if let short = renderer.object("shortBylineText")?.array("runs") {
            detailRuns = short
        } else {
            detailRuns = []
        }
        let (artists, album) = artistAndAlbum(from: detailRuns)
        let durationSeconds = renderer.object("lengthText")?.array("runs")
            .flatMap { runs in runs.compactMap { $0.string("text") }.compactMap(parseDuration).first }
        return Track(
            id: videoId,
            title: title,
            artists: artists,
            album: album,
            durationSeconds: durationSeconds,
            thumbnails: thumbnails(in: renderer)
        )
    }

    /// `videoRenderer` / `compactVideoRenderer` (plain YouTube rows).
    /// Mirrors Android `parseVideoRenderer`.
    static func parseVideoTrack(from renderer: JSONValue) -> Track? {
        guard let videoId = renderer.string("videoId") else { return nil }
        guard let title = renderer.object("title")?.text?.trimmedNonEmpty else { return nil }
        let artist = renderer.object("ownerText")?.array("runs")?.first?.string("text")
            ?? renderer.object("shortBylineText")?.array("runs")?.first?.string("text")
            ?? "Unknown artist"
        let durationSeconds = renderer.object("lengthText")?.string("simpleText").flatMap(parseDuration)
            ?? renderer.string("lengthSeconds").flatMap(Int.init)
        return Track(
            id: videoId,
            title: title,
            artists: [ArtistRef(id: "", name: artist)],
            durationSeconds: durationSeconds,
            thumbnails: thumbnails(in: renderer),
            isVideo: true
        )
    }

    /// All song rows anywhere in a response, deduplicated by video id.
    /// Mirrors Android `parseSongRenderers`.
    static func parseTracks(in root: JSONValue) -> [Track] {
        var tracks: [Track] = []
        var card: [JSONValue] = []
        root.collectObjects(key: "musicCardShelfRenderer", into: &card)
        tracks += card.compactMap(parseCardShelfTrack)
        var rows: [JSONValue] = []
        root.collectObjects(key: "musicResponsiveListItemRenderer", into: &rows)
        tracks += rows.filter { !isSuggestionItem($0) }.compactMap(parseTrack)
        var panels: [JSONValue] = []
        root.collectObjects(key: "playlistPanelVideoRenderer", into: &panels)
        tracks += panels.compactMap(parsePlaylistPanelTrack)
        var playlistVideos: [JSONValue] = []
        root.collectObjects(key: "playlistVideoRenderer", into: &playlistVideos)
        tracks += playlistVideos.compactMap(parsePlaylistVideoTrack)
        if tracks.isEmpty {
            tracks += parseVideoTracks(in: root)
        }
        return dedupe(tracks)
    }

    /// Plain YouTube video rows anywhere in a response.
    static func parseVideoTracks(in root: JSONValue) -> [Track] {
        var renderers: [JSONValue] = []
        root.collectObjects(key: "videoRenderer", into: &renderers)
        root.collectObjects(key: "compactVideoRenderer", into: &renderers)
        return dedupe(renderers.compactMap(parseVideoTrack))
    }

    /// Radio / queue rows in exact order. Mirrors Android
    /// `parseRadioResponse` (tracks only; continuation handling lives in
    /// the client).
    static func parseRadioTracks(in root: JSONValue) -> [Track] {
        var tracks: [Track] = []

        if let continuation = root.object("continuationContents")?.object("playlistPanelContinuation") {
            if let contents = continuation.array("contents") {
                for element in contents {
                    if let renderer = element.object("playlistPanelVideoRenderer") {
                        if let track = parsePlaylistPanelTrack(from: renderer) { tracks.append(track) }
                    } else if let wrapper = element.object("playlistPanelVideoWrapperRenderer"),
                              let primary = wrapper.object("primaryRenderer"),
                              let renderer = primary.object("playlistPanelVideoRenderer") {
                        if let track = parsePlaylistPanelTrack(from: renderer) { tracks.append(track) }
                    }
                }
            }
        } else {
            var panels: [JSONValue] = []
            root.collectObjects(key: "playlistPanelRenderer", into: &panels)
            if let panel = panels.first, let contents = panel.array("contents") {
                for element in contents {
                    if let renderer = element.object("playlistPanelVideoRenderer") {
                        if let track = parsePlaylistPanelTrack(from: renderer) { tracks.append(track) }
                    } else if let wrapper = element.object("playlistPanelVideoWrapperRenderer"),
                              let primary = wrapper.object("primaryRenderer"),
                              let renderer = primary.object("playlistPanelVideoRenderer") {
                        if let track = parsePlaylistPanelTrack(from: renderer) { tracks.append(track) }
                    }
                }
            }
        }

        if tracks.isEmpty {
            var renderers: [JSONValue] = []
            root.collectObjects(key: "playlistPanelVideoRenderer", into: &renderers)
            tracks = renderers.compactMap(parsePlaylistPanelTrack)
        }
        return dedupe(tracks)
    }

    private static func dedupe(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { track in
            guard !track.id.isEmpty, seen.insert(track.id).inserted else { return false }
            return true
        }
    }

    // MARK: - Entities (artists / albums / playlists)

    enum EntityKind {
        case artist
        case album
        case playlist
    }

    struct ParsedEntity {
        let kind: EntityKind
        let id: String
        let name: String
        let artist: String?
        let subtitle: String?
        let thumbnails: [Thumbnail]
    }

    /// Artist / album / playlist rows anywhere in a response, classified by
    /// browse-id prefix. Mirrors Android `parseEntity` +
    /// `parseTwoRowEntity`.
    static func parseEntities(in root: JSONValue) -> [ParsedEntity] {
        var entities: [ParsedEntity] = []
        var rows: [JSONValue] = []
        root.collectObjects(key: "musicResponsiveListItemRenderer", into: &rows)
        for row in rows {
            if let entity = parseEntity(from: row) { entities.append(entity) }
        }
        var twoRow: [JSONValue] = []
        root.collectObjects(key: "musicTwoRowItemRenderer", into: &twoRow)
        for row in twoRow {
            if let entity = parseTwoRowEntity(from: row) { entities.append(entity) }
        }
        var seen = Set<String>()
        return entities.filter { seen.insert($0.id + $0.name).inserted }
    }

    private static func classify(browseId: String, subtitle: String, name: String) -> EntityKind? {
        if browseId.hasPrefix("UC") { return .artist }
        if browseId.hasPrefix("MPRE") { return .album }
        if browseId.hasPrefix("VL") || browseId.hasPrefix("OLAK") || browseId.hasPrefix("PL") || browseId.hasPrefix("RD") {
            // A non-MPRE browse id is a release when its subtitle says so.
            let lower = subtitle.lowercased()
            let nameLower = name.lowercased()
            let isRelease = lower.contains("album") || lower.contains("single")
                || lower.contains("ep") || lower.contains("disc")
                || (lower.contains("playlist") && (nameLower.contains("album") || nameLower.contains("ep")))
            return isRelease ? .album : .playlist
        }
        return nil
    }

    private static func parseEntity(from renderer: JSONValue) -> ParsedEntity? {
        guard let browseId = renderer.object("navigationEndpoint")?.object("browseEndpoint")?.string("browseId") else {
            return nil
        }
        let columns = renderer.array("flexColumns") ?? []
        func columnRuns(_ index: Int) -> [JSONValue] {
            at(columns, index)?.object("musicResponsiveListItemFlexColumnRenderer")?.object("text")?.array("runs") ?? []
        }
        guard let name = columnRuns(0).compactMap({ $0.string("text") }).joined().trimmedNonEmpty else {
            return nil
        }
        let details = columnRuns(1)
        let subtitle = details.compactMap { $0.string("text")?.trimmedNonEmpty }
            .filter { !["•", "·", "Artist", "Album", "EP", "Single"].contains($0) }
            .joined(separator: " • ")
            .trimmedNonEmpty
        guard let kind = classify(browseId: browseId, subtitle: subtitle ?? "", name: name) else { return nil }
        let artist: String? = {
            guard kind == .album else { return nil }
            return details.first(where: { run in
                run.object("navigationEndpoint")?.object("browseEndpoint")?.string("browseId")?.hasPrefix("UC") == true
            })?.string("text")
                ?? details.compactMap { $0.string("text") }.first(where: isLikelyArtist)
        }()
        return ParsedEntity(
            kind: kind,
            id: browseId,
            name: name,
            artist: artist,
            subtitle: subtitle,
            thumbnails: thumbnails(in: renderer)
        )
    }

    private static func parseTwoRowEntity(from renderer: JSONValue) -> ParsedEntity? {
        let navigation: JSONValue?
        if let browse = renderer.object("navigationEndpoint")?.object("browseEndpoint") {
            navigation = browse
        } else if let title = renderer.object("title"),
                  let runs = title.array("runs"),
                  let first = runs.first,
                  let browse = first.object("navigationEndpoint")?.object("browseEndpoint") {
            navigation = browse
        } else {
            navigation = nil
        }

        guard let browseId = navigation?.string("browseId") else { return nil }
        guard let name = renderer.object("title")?.text?.trimmedNonEmpty else { return nil }
        let subtitleRuns = renderer.object("subtitle")?.array("runs") ?? []
        let subtitle = subtitleRuns.compactMap { $0.string("text")?.trimmedNonEmpty }
            .filter { !["•", "·", "Artist", "Album", "EP", "Single"].contains($0) }
            .joined(separator: " • ")
            .trimmedNonEmpty
        guard let kind = classify(browseId: browseId, subtitle: subtitle ?? "", name: name) else { return nil }
        let artist: String? = {
            guard kind == .album else { return nil }
            return subtitleRuns.first(where: { run in
                run.object("navigationEndpoint")?.object("browseEndpoint")?.string("browseId")?.hasPrefix("UC") == true
            })?.string("text")
                ?? subtitleRuns.compactMap { $0.string("text") }.first(where: isLikelyArtist)
        }()
        return ParsedEntity(
            kind: kind,
            id: browseId,
            name: name,
            artist: artist,
            subtitle: subtitle,
            thumbnails: thumbnails(in: renderer)
        )
    }

    // MARK: - Shelves / feed

    private static func shelfHeading(_ shelf: JSONValue) -> String {
        shelf.object("title")?.text
            ?? shelf.object("header")?.object("musicCarouselShelfBasicHeaderRenderer")?.object("title")?.text
            ?? shelf.object("header")?.object("musicShelfHeaderRenderer")?.object("title")?.text
            ?? ""
    }

    private static func shelfMoreBrowseId(_ shelf: JSONValue) -> String? {
        if let header = shelf.object("header") {
            if let basic = header.object("musicCarouselShelfBasicHeaderRenderer"),
               let more = basic.object("moreContentButton"),
               let button = more.object("buttonRenderer"),
               let endpoint = button.object("navigationEndpoint"),
               let browse = endpoint.object("browseEndpoint"),
               let browseId = browse.string("browseId"), !browseId.isEmpty {
                return browseId
            }
            if let basic = header.object("musicShelfHeaderRenderer"),
               let more = basic.object("moreContentButton"),
               let button = more.object("buttonRenderer"),
               let endpoint = button.object("navigationEndpoint"),
               let browse = endpoint.object("browseEndpoint"),
               let browseId = browse.string("browseId"), !browseId.isEmpty {
                return browseId
            }
        }
        return nil
    }

    /// One two-row card as a feed item: a playable song, an album, or a
    /// playlist. Artist cards are skipped, matching the Android home parser.
    static func parseTwoRowFeedItem(_ renderer: JSONValue) -> FeedItem? {
        if let track = parseTwoRowTrack(from: renderer) {
            return .track(track)
        }

        let navigation: JSONValue?
        if let browse = renderer.object("navigationEndpoint")?.object("browseEndpoint") {
            navigation = browse
        } else if let title = renderer.object("title"),
                  let runs = title.array("runs"),
                  let first = runs.first,
                  let browse = first.object("navigationEndpoint")?.object("browseEndpoint") {
            navigation = browse
        } else if let overlay = renderer.object("thumbnailOverlay")?.object("musicItemThumbnailOverlayRenderer")?.object("content")?.object("musicPlayButtonRenderer")?.object("playNavigationEndpoint")?.object("watchEndpoint") {
            navigation = overlay
        } else if let browse = renderer.object("onTap")?.object("browseEndpoint") {
            navigation = browse
        } else {
            navigation = nil
        }

        guard let browseId = navigation?.string("browseId") ?? navigation?.string("playlistId"),
              !browseId.isEmpty, !browseId.hasPrefix("UC") else { return nil }
        guard let title = renderer.object("title")?.text?.trimmedNonEmpty else { return nil }
        let subtitleRuns = renderer.object("subtitle")?.array("runs") ?? []
        let author = subtitleRuns.first(where: { run in
            run.object("navigationEndpoint")?.object("browseEndpoint")?.string("browseId")?.hasPrefix("UC") == true
        })?.string("text")
            ?? subtitleRuns.first?.string("text")
                .flatMap { $0.caseInsensitiveCompare("Playlist") == .orderedSame ? nil : $0 }
        let thumbs = thumbnails(in: renderer)
        if browseId.hasPrefix("MPRE") {
            return .album(AlbumRef(id: browseId, title: title, thumbnails: thumbs))
        }
        let playlistId = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
        let trackCount = subtitleRuns.compactMap { $0.string("text") }
            .last(where: { $0.lowercased().contains("song") || $0.lowercased().contains("track") })
            .flatMap { text in text.split(separator: " ").compactMap { Int($0) }.first }
        return .playlist(PlaylistRef(
            id: playlistId,
            title: title,
            author: author?.trimmedNonEmpty,
            thumbnails: thumbs,
            trackCount: trackCount
        ))
    }

    /// `musicCarouselShelfRenderer` -> one feed section. Mirrors Android
    /// `parseCarouselShelf`.
    static func parseCarouselShelf(_ renderer: JSONValue) -> FeedSection? {
        guard let title = shelfHeading(renderer).trimmedNonEmpty else { return nil }
        guard let contents = renderer.array("contents") else { return nil }
        var items: [FeedItem] = []
        for element in contents {
            if let twoRow = element.object("musicTwoRowItemRenderer") {
                if let item = parseTwoRowFeedItem(twoRow) { items.append(item) }
            } else if let responsive = element.object("musicResponsiveListItemRenderer") {
                if let track = parseTrack(from: responsive) { items.append(.track(track)) }
            }
        }
        guard !items.isEmpty else { return nil }
        return FeedSection(title: title, browseId: shelfMoreBrowseId(renderer), items: items)
    }

    /// `musicShelfRenderer` (quick picks / plain lists) -> one feed section.
    static func parseMusicShelf(_ renderer: JSONValue) -> FeedSection? {
        guard let title = shelfHeading(renderer).trimmedNonEmpty else { return nil }
        guard let contents = renderer.array("contents") else { return nil }
        var items: [FeedItem] = []
        for element in contents {
            if let responsive = element.object("musicResponsiveListItemRenderer") {
                if let track = parseTrack(from: responsive) { items.append(.track(track)) }
            } else if let twoRow = element.object("musicTwoRowItemRenderer") {
                if let item = parseTwoRowFeedItem(twoRow) { items.append(item) }
            }
        }
        guard !items.isEmpty else { return nil }
        return FeedSection(title: title, browseId: shelfMoreBrowseId(renderer), items: items)
    }

    /// Home / charts shelves. Prefers the section list in document order
    /// and falls back to collecting every carousel in the response.
    /// Mirrors Android `parseHomeShelves`.
    static func parseFeedSections(in root: JSONValue) -> [FeedSection] {
        if let contentsRoot = root.object("contents"),
           let browseResults = contentsRoot.object("singleColumnBrowseResultsRenderer"),
           let tabs = browseResults.array("tabs"),
           let firstTab = tabs.first,
           let tabRenderer = firstTab.object("tabRenderer"),
           let content = tabRenderer.object("content"),
           let sectionRenderer = content.object("sectionListRenderer"),
           let contents = sectionRenderer.array("contents") {
            var sections: [FeedSection] = []
            for element in contents {
                if let carousel = element.object("musicCarouselShelfRenderer"),
                   let section = parseCarouselShelf(carousel) {
                    sections.append(section)
                } else if let shelf = element.object("musicShelfRenderer"),
                          let section = parseMusicShelf(shelf) {
                    sections.append(section)
                }
            }
            if !sections.isEmpty { return sections }
        }
        var carousels: [JSONValue] = []
        root.collectObjects(key: "musicCarouselShelfRenderer", into: &carousels)
        var sections = carousels.compactMap(parseCarouselShelf)
        var shelves: [JSONValue] = []
        root.collectObjects(key: "musicShelfRenderer", into: &shelves)
        sections += shelves.compactMap(parseMusicShelf)
        return sections
    }

    // MARK: - Combined search results

    /// Classifies a whole (unfiltered) search response into songs, albums,
    /// artists, playlists and videos.
    static func parseSearchResults(from root: JSONValue) -> SearchResults {
        let songs = parseTracks(in: root)
        let videos = parseVideoTracks(in: root)
        var artists: [ArtistRef] = []
        var albums: [AlbumRef] = []
        var playlists: [PlaylistRef] = []
        for entity in parseEntities(in: root) {
            switch entity.kind {
            case .artist:
                if !artists.contains(where: { $0.id == entity.id }) {
                    artists.append(ArtistRef(id: entity.id, name: entity.name, thumbnails: entity.thumbnails))
                }
            case .album:
                if !albums.contains(where: { $0.id == entity.id }) {
                    albums.append(AlbumRef(id: entity.id, title: entity.name, thumbnails: entity.thumbnails))
                }
            case .playlist:
                if !playlists.contains(where: { $0.id == entity.id }) {
                    let playlistId = entity.id.hasPrefix("VL") ? String(entity.id.dropFirst(2)) : entity.id
                    playlists.append(PlaylistRef(
                        id: playlistId,
                        title: entity.name,
                        author: entity.artist,
                        thumbnails: entity.thumbnails
                    ))
                }
            }
        }
        return SearchResults(songs: songs, albums: albums, artists: artists, playlists: playlists, videos: videos)
    }

    // MARK: - Artist / album / playlist pages

    /// The "more" browse id of a songs shelf (bottom endpoint), used to
    /// fetch the full top-tracks list for an artist.
    static func songsShelfMoreBrowseId(in root: JSONValue) -> String? {
        var shelves: [JSONValue] = []
        root.collectObjects(key: "musicShelfRenderer", into: &shelves)
        root.collectObjects(key: "musicCarouselShelfRenderer", into: &shelves)
        for shelf in shelves {
            let heading = shelfHeading(shelf).lowercased()
            guard heading.contains("song") || heading.contains("track") else { continue }

            let endpoint: JSONValue?
            if let bottom = shelf.object("bottomEndpoint"),
               let browse = bottom.object("browseEndpoint") {
                endpoint = browse
            } else if let first = shelf.object("bottomText")?.array("runs")?.first,
                      let nav = first.object("navigationEndpoint"),
                      let browse = nav.object("browseEndpoint") {
                endpoint = browse
            } else if let first = shelf.object("title")?.array("runs")?.first,
                      let nav = first.object("navigationEndpoint"),
                      let browse = nav.object("browseEndpoint") {
                endpoint = browse
            } else if let header = shelf.object("header"),
                      let basic = header.object("musicCarouselShelfBasicHeaderRenderer"),
                      let more = basic.object("moreContentButton"),
                      let button = more.object("buttonRenderer"),
                      let nav = button.object("navigationEndpoint"),
                      let browse = nav.object("browseEndpoint") {
                endpoint = browse
            } else {
                endpoint = nil
            }

            if let browseId = endpoint?.string("browseId"), !browseId.isEmpty {
                return browseId
            }
        }
        return nil
    }

    /// Artist page. Mirrors the header/shelf reading of Android
    /// `fetchArtistPage`.
    static func parseArtistDetail(id: String, in root: JSONValue) -> ArtistDetail {
        let header = root.object("header")?.object("musicVisualHeaderRenderer")
            ?? root.object("header")?.object("musicImmersiveHeaderRenderer")
            ?? root.object("header")?.object("musicHeaderRenderer")
        let name = header?.object("title")?.text?.trimmedNonEmpty ?? "Artist"

        let subscribers: String?
        if let header {
            if let subscribe = header.object("subscriptionButton")?.object("subscribeButtonRenderer"),
               let text = subscribe.object("subscriberCountText")?.text?.trimmedNonEmpty {
                subscribers = text
            } else if let subtitle = header.object("subtitle")?.text?.trimmedNonEmpty {
                subscribers = subtitle
            } else if let strapline = header.object("straplineTextOne")?.text?.trimmedNonEmpty {
                subscribers = strapline
            } else {
                subscribers = nil
            }
        } else {
            subscribers = nil
        }
        let thumbs = header.map { thumbnails(in: $0) } ?? []

        var topSongs: [Track] = []
        var albums: [AlbumRef] = []
        var singles: [AlbumRef] = []
        var playlists: [PlaylistRef] = []
        var shelves: [JSONValue] = []
        root.collectObjects(key: "musicShelfRenderer", into: &shelves)
        root.collectObjects(key: "musicCarouselShelfRenderer", into: &shelves)
        for shelf in shelves {
            let heading = shelfHeading(shelf).lowercased()
            if heading.contains("song") || heading.contains("track") {
                if topSongs.isEmpty { topSongs = parseTracks(in: shelf) }
            } else if heading.contains("album") {
                albums += albumRefs(in: shelf)
            } else if heading.contains("single") || heading.contains("ep") {
                singles += albumRefs(in: shelf)
            } else if heading.contains("playlist") {
                playlists += playlistRefs(in: shelf)
            }
        }
        return ArtistDetail(
            id: id,
            name: name,
            thumbnails: thumbs,
            subscribers: subscribers,
            topSongs: topSongs,
            albums: albums,
            singles: singles,
            playlists: playlists
        )
    }

    private static func albumRefs(in shelf: JSONValue) -> [AlbumRef] {
        parseEntities(in: shelf)
            .filter { $0.kind == .album }
            .map { AlbumRef(id: $0.id, title: $0.name, thumbnails: $0.thumbnails) }
    }

    private static func playlistRefs(in shelf: JSONValue) -> [PlaylistRef] {
        parseEntities(in: shelf)
            .filter { $0.kind == .playlist }
            .map { entity in
                let playlistId = entity.id.hasPrefix("VL") ? String(entity.id.dropFirst(2)) : entity.id
                return PlaylistRef(id: playlistId, title: entity.name, author: entity.artist, thumbnails: entity.thumbnails)
            }
    }

    /// Album page. Mirrors Android `fetchAlbumPage`.
    static func parseAlbum(id: String, in root: JSONValue) -> Album {
        var headers: [JSONValue] = []
        root.collectObjects(key: "musicResponsiveHeaderRenderer", into: &headers)
        let header = root.object("header")?.object("musicDetailHeaderRenderer")
            ?? root.object("header")?.object("musicResponsiveHeaderRenderer")
            ?? headers.first
        let title = header?.object("title")?.text?.trimmedNonEmpty ?? "Album"
        let subRuns = header?.object("subtitle")?.array("runs") ?? []
        let artistRuns = subRuns.filter { run in
            run.object("navigationEndpoint")?.object("browseEndpoint")?.string("browseId")?.hasPrefix("UC") == true
        }
        let artists: [ArtistRef] = {
            if !artistRuns.isEmpty {
                return artistRuns.compactMap { run in
                    guard let name = run.string("text")?.trimmedNonEmpty else { return nil }
                    let browseId = run.object("navigationEndpoint")?.object("browseEndpoint")?.string("browseId") ?? ""
                    return ArtistRef(id: browseId, name: name)
                }
            }
            let beforeMeta = subRuns.prefix(while: { run in
                guard let text = run.string("text")?.trimmedNonEmpty else { return false }
                if text.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil { return false }
                if ["•", "·", "Playlist", "Album", "EP", "Single"].contains(text) { return false }
                let lower = text.lowercased()
                return !lower.contains("song") && !lower.contains("min")
            }).compactMap { $0.string("text")?.trimmedNonEmpty }
                .filter { $0 != "," && $0 != "&" }
            if !beforeMeta.isEmpty {
                return [ArtistRef(id: "", name: beforeMeta.joined(separator: ", "))]
            }
            return [ArtistRef(id: "", name: "Various Artists")]
        }()
        let year = subRuns.compactMap { $0.string("text")?.trimmedNonEmpty }
            .first(where: { $0.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil })
            .flatMap(Int.init)
        let description = header?.object("description")?.text?.trimmedNonEmpty
        let thumbs = header.map { thumbnails(in: $0) } ?? []
        return Album(
            id: id,
            title: title,
            artists: artists,
            year: year,
            thumbnails: thumbs,
            tracks: parseTracks(in: root),
            description: description
        )
    }

    /// Playlist page. Mirrors Android's playlist header reading
    /// (`playlistHeader` / `fetchOwnedPlaylistImpl`).
    static func parsePlaylist(id: String, in root: JSONValue) -> Playlist {
        var headers: [JSONValue] = []
        root.collectObjects(key: "musicDetailHeaderRenderer", into: &headers)
        let header: JSONValue?
        if let direct = root.object("header")?.object("musicDetailHeaderRenderer") {
            header = direct
        } else if let editable = root.object("header")?.object("musicEditablePlaylistDetailHeaderRenderer")?.object("header"),
                  let detail = editable.object("musicDetailHeaderRenderer") {
            header = detail
        } else if let musicHeader = root.object("header")?.object("musicHeaderRenderer") {
            header = musicHeader
        } else {
            header = headers.first
        }

        let title = header?.object("title")?.text?.trimmedNonEmpty ?? "Playlist"
        let subRuns = header?.object("subtitle")?.array("runs") ?? []
        let author = subRuns.first(where: { run in
            run.object("navigationEndpoint")?.object("browseEndpoint")?.string("browseId")?.hasPrefix("UC") == true
        })?.string("text")?.trimmedNonEmpty
            ?? subRuns.first?.string("text")?.trimmedNonEmpty
        let description = header?.object("description")?.text?.trimmedNonEmpty
        let thumbs = header.map { thumbnails(in: $0) } ?? []
        return Playlist(
            id: id,
            title: title,
            author: author,
            thumbnails: thumbs,
            tracks: parseTracks(in: root),
            description: description
        )
    }

    // MARK: - Moods & genres

    /// The moods/genres page is a grid of navigation buttons. Each button
    /// becomes a playlist entry whose id encodes the category browse id and
    /// its params (`browseId:params`); `InnerTubeClient.playlist(id:)`
    /// decodes that form back into a browse call.
    static func parseGenres(in root: JSONValue) -> [FeedSection] {
        var buttons: [JSONValue] = []
        root.collectObjects(key: "musicNavigationButtonRenderer", into: &buttons)
        var items: [FeedItem] = []
        var seen = Set<String>()
        for button in buttons {
            guard let title = button.object("buttonText")?.text?.trimmedNonEmpty else { continue }
            let endpoint = button.object("clickCommand")?.object("browseEndpoint")
                ?? button.object("navigationEndpoint")?.object("browseEndpoint")
            guard let browseId = endpoint?.string("browseId"), !browseId.isEmpty else { continue }
            let params = endpoint?.string("params")
            let id = params.map { "\(browseId):\($0)" } ?? browseId
            guard seen.insert(id).inserted else { continue }
            items.append(.playlist(PlaylistRef(id: id, title: title, thumbnails: thumbnails(in: button))))
        }
        if items.isEmpty {
            items = parseEntities(in: root)
                .filter { $0.kind == .playlist }
                .map { .playlist(PlaylistRef(id: $0.id, title: $0.name, author: $0.artist, thumbnails: $0.thumbnails)) }
        }
        guard !items.isEmpty else { return [] }
        return [FeedSection(title: "Moods & Genres", items: items)]
    }

    // MARK: - Player / streamingData

    struct RawAudioFormat {
        let url: String?
        let cipher: String?
        let itag: Int
        let mimeType: String
        let bitrate: Int
        let contentLength: Int?
        let isAdaptive: Bool
        let audioSampleRate: Int?
        let approxDurationMs: Int?
        let isDrc: Bool
    }

    struct StreamParseResult {
        let formats: [RawAudioFormat]
        let durationSeconds: Int?
        let isLive: Bool
        let playabilityStatus: String?
        let reason: String?
    }

    /// `streamingData` formats/adaptiveFormats plus playability info.
    /// Mirrors the format reading in Android
    /// `resolveDirectClientStream`.
    static func parseStreamFormats(in root: JSONValue) -> StreamParseResult {
        let status = root.object("playabilityStatus")
        let playabilityStatus = status?.string("status")
        let reason = status?.string("reason")
        let details = root.object("videoDetails")
        let durationSeconds = details?.string("lengthSeconds").flatMap(Int.init)
        let isLive = details?.bool("isLiveContent") ?? false

        var formats: [RawAudioFormat] = []
        let streaming = root.object("streamingData")
        for (key, isAdaptive) in [("formats", false), ("adaptiveFormats", true)] {
            guard let list = streaming?.array(key) else { continue }
            for element in list {
                guard let mimeType = element.string("mimeType") else { continue }
                let url = element.string("url")
                let cipher = element.string("signatureCipher") ?? element.string("cipher")
                let isDrc = element.string("isDrc") == "true"
                    || isDrcAudioURL(url ?? "")
                formats.append(RawAudioFormat(
                    url: url,
                    cipher: cipher,
                    itag: element.int("itag") ?? 0,
                    mimeType: mimeType,
                    bitrate: element.int("bitrate") ?? 0,
                    contentLength: element.int("contentLength"),
                    isAdaptive: isAdaptive,
                    audioSampleRate: element.string("audioSampleRate").flatMap(Int.init),
                    approxDurationMs: element.string("approxDurationMs").flatMap(Int.init),
                    isDrc: isDrc
                ))
            }
        }
        return StreamParseResult(
            formats: formats,
            durationSeconds: durationSeconds,
            isLive: isLive,
            playabilityStatus: playabilityStatus,
            reason: reason
        )
    }

    /// googlevideo marks the Stable-volume variant with `drc=1` in its
    /// `xtags` query parameter. Mirrors Android `isDrcAudioUrl`.
    static func isDrcAudioURL(_ url: String) -> Bool {
        guard let xtagsRange = url.range(of: "xtags=") else { return false }
        let rest = url[xtagsRange.upperBound...]
        let xtags = rest.split(separator: "&", maxSplits: 1).first.map(String.init) ?? String(rest)
        let decoded = xtags.removingPercentEncoding ?? xtags
        return decoded.contains("drc=1")
    }

    /// The codec token inside a mime type, e.g. `opus` from
    /// `audio/webm; codecs="opus"`. Parsed by hand: a regex with the
    /// quotes in it would break the repo's brace scanner, and the shape
    /// is fixed (`codecs="first, second"`). Returns the first codec.
    static func codec(from mimeType: String) -> String? {
        guard let codecsRange = mimeType.range(of: "codecs=") ?? mimeType.range(of: "codec=") else {
            return nil
        }
        let after = mimeType[codecsRange.upperBound...]
        // YouTube always quotes the codecs value ("opus" / 'opus').
        guard after.hasPrefix("\"") || after.hasPrefix("'") else { return nil }
        let quote = after.first!
        let value = after.dropFirst().prefix(while: { $0 != quote })
        let token = value.components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return token.isEmpty ? nil : token
    }

    /// Whether the format is an audio stream this app can play. Mirrors
    /// Android `isCompatibleAudioCandidate`.
    static func isCompatibleAudio(mimeType: String) -> Bool {
        let mime = mimeType.lowercased().components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces) ?? mimeType.lowercased()
        let codecValue = (codec(from: mimeType) ?? "").lowercased()
        switch mime {
        case "audio/webm":
            return codecValue.isEmpty || codecValue.contains("opus") || codecValue.contains("vorbis")
        case "audio/mp4", "audio/m4a":
            return codecValue.isEmpty || codecValue.contains("mp4a") || codecValue.contains("aac")
        case "audio/ogg":
            return codecValue.isEmpty || codecValue.contains("opus") || codecValue.contains("vorbis")
        case "audio/mpeg":
            return true
        default:
            return false
        }
    }

    /// Appends the GVS `pot=` token to a googlevideo URL, mirroring
    /// Android `appendPoToken`.
    static func appendingPoToken(to urlString: String, token: String) -> String {
        guard urlString.contains("googlevideo.com") else { return urlString }
        guard var components = URLComponents(string: urlString) else { return urlString }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "pot" }
        items.append(URLQueryItem(name: "pot", value: token))
        components.queryItems = items
        return components.string ?? urlString
    }
}
