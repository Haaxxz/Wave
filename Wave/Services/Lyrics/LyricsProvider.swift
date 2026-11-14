import Foundation

// MARK: - Lyrics provider
//
// Tries the public, keyless lyrics sources in priority order and returns
// the first usable result, `nil` when nothing is found:
//
//  1. LRCLIB — https://lrclib.net/api/get (exact) then /api/search. No key.
//  2. SimpMusic — https://api-lyrics.simpmusic.org/v1/{videoId}. No key.
//     Keyed on the playing video id, so the exact cut is looked up.
//  3. LyricsPlus — $host/v2/lyrics/get across its public mirrors. No key.
//  4. Unison — https://unison.boidu.dev/lyrics (community database). No key.
//  5. Bini — https://lyrics-api.binimum.org/ (Apple TTML / LRC catalogue).
//     No key.
//
// Deliberately NOT in the chain: Kugou (its KRC format is compressed and
// needs a dedicated decoder), Megalobiz (HTML scraping), the LastWave
// lyrics API (needs a private token), Musixmatch / Genius / Spotify /
// Apple Music (API keys or account auth). Those are documented in
// `docs/SPECS.md`; adding one means adding its auth, not just its URL.
//
// LRC and TTML parsing are static so the unit tests can exercise them
// without the network.

@Observable
final class LyricsProvider: LyricsService {
    static let shared = LyricsProvider()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    func lyrics(for track: Track) async -> Lyrics? {
        let artist = track.artistNames
        guard !track.title.isEmpty, !artist.isEmpty else { return nil }

        if let found = await lrclib(track: track) { return found }
        if let found = await simpMusic(videoId: track.id, durationSeconds: track.durationSeconds) { return found }
        if let found = await lyricsPlus(track: track) { return found }
        if let found = await unison(track: track) { return found }
        if let found = await bini(track: track) { return found }
        return nil
    }

    // MARK: - HTTP helpers

    private func getJSON(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Wave-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    private func getText(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Wave-iOS/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private func url(base: String, query: [(String, String?)]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = query.compactMap { key, value in
            value.map { URLQueryItem(name: key, value: $0) }
        }
        return components.url
    }

    // MARK: - LRCLIB

    private struct LrclibRecord: Decodable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    private func lrclib(track: Track) async -> Lyrics? {
        let artist = track.artistNames
        // Exact matches, strictest first: a correct album/duration pins the
        // right version (studio vs live/remix).
        let attempts: [(album: String?, duration: Int?)] = [
            (track.album?.title, track.durationSeconds),
            (nil, track.durationSeconds),
            (nil, nil),
        ]
        for attempt in attempts {
            if let record = await lrclibExact(
                title: track.title, artist: artist,
                album: attempt.album, durationSeconds: attempt.duration),
               let lyrics = lyrics(from: record, source: "LRCLIB") {
                return lyrics
            }
        }
        // Cleaned title/artist, then the search fallback.
        let cleanedTitle = Self.cleanTrackTitle(track.title)
        let cleanedArtist = Self.cleanArtistName(artist)
        if cleanedTitle != track.title || cleanedArtist != artist {
            for attempt in attempts {
                if let record = await lrclibExact(
                    title: cleanedTitle, artist: cleanedArtist,
                    album: attempt.album, durationSeconds: attempt.duration),
                   let lyrics = lyrics(from: record, source: "LRCLIB") {
                    return lyrics
                }
            }
        }
        return await lrclibSearch(title: cleanedTitle, artist: cleanedArtist, durationSeconds: track.durationSeconds, rawTitle: track.title)
    }

    private func lrclibExact(title: String, artist: String, album: String?, durationSeconds: Int?) async -> LrclibRecord? {
        guard let url = url(base: "https://lrclib.net/api/get", query: [
            ("track_name", title.trimmingCharacters(in: .whitespaces)),
            ("artist_name", artist.trimmingCharacters(in: .whitespaces)),
            ("album_name", album?.trimmingCharacters(in: .whitespaces)),
            ("duration", durationSeconds.map(String.init)),
        ]), let data = await getJSON(url) else { return nil }
        return try? JSONDecoder().decode(LrclibRecord.self, from: data)
    }

    private func lrclibSearch(title: String, artist: String, durationSeconds: Int?, rawTitle: String) async -> Lyrics? {
        guard let url = url(base: "https://lrclib.net/api/search", query: [
            ("q", "\(artist) \(title)".trimmingCharacters(in: .whitespaces)),
        ]), let data = await getJSON(url),
              let list = try? JSONDecoder().decode([LrclibRecord].self, from: data),
              !list.isEmpty else { return nil }

        // Score candidates on artist/title only; duration is a soft
        // preference — YouTube/music-video lengths routinely differ from
        // the database's audio length. A live/remix/cover tag present on
        // one side but not the other rejects the record at every tier.
        let matched = list.compactMap { candidate -> (record: LrclibRecord, delta: Double)? in
            guard Self.artistMatches(candidate.artistName ?? "", artist),
                  Self.titlesMatch(candidate.trackName ?? "", title),
                  Self.sameVersion(rawTitle, candidate.trackName ?? "") else { return nil }
            let delta: Double
            if let durationSeconds, durationSeconds > 0,
               let candidateDuration = candidate.duration, candidateDuration > 0 {
                delta = abs(candidateDuration - Double(durationSeconds))
            } else {
                delta = 0
            }
            return (candidate, delta)
        }.sorted { $0.delta < $1.delta }
        guard !matched.isEmpty else { return nil }

        func pick(hasSynced: Bool, maxDelta: Double) -> LrclibRecord? {
            matched.first { $0.delta <= maxDelta && ((hasSynced ? !$0.record.syncedLyrics.isNilOrBlank : !$0.record.plainLyrics.isNilOrBlank)) }?.record
        }
        let record = pick(hasSynced: true, maxDelta: 8)
            ?? pick(hasSynced: true, maxDelta: 30)
            ?? matched.first { !$0.record.syncedLyrics.isNilOrBlank }?.record
            ?? pick(hasSynced: false, maxDelta: 8)
            ?? pick(hasSynced: false, maxDelta: 30)
            ?? matched.first { !$0.record.plainLyrics.isNilOrBlank }?.record
            ?? matched.first { $0.record.instrumental == true }?.record
        guard let record else { return nil }
        return lyrics(from: record, source: "LRCLIB")
    }

    private func lyrics(from record: LrclibRecord, source: String) -> Lyrics? {
        if let synced = record.syncedLyrics, !synced.isBlank {
            let lines = Self.parseLRC(synced)
            if !lines.isEmpty {
                return Lyrics(synced: lines, plainText: record.plainLyrics.nilIfBlank, source: source)
            }
        }
        if let plain = record.plainLyrics, !plain.isBlank {
            return Lyrics(synced: nil, plainText: plain, source: source)
        }
        if record.instrumental == true {
            return Lyrics(synced: nil, plainText: "[Instrumental]", source: source)
        }
        return nil
    }

    // MARK: - SimpMusic

    private struct SimpResponse: Decodable {
        var success: Bool?
        var data: [SimpTrack]?
    }

    private struct SimpTrack: Decodable {
        var duration: Int?
        var richSyncLyrics: String?
        var syncedLyrics: String?
        var plainLyrics: String?
    }

    private func simpMusic(videoId: String, durationSeconds: Int?) async -> Lyrics? {
        guard let url = URL(string: "https://api-lyrics.simpmusic.org/v1/\(videoId)"),
              let data = await getJSON(url),
              let response = try? JSONDecoder().decode(SimpResponse.self, from: data),
              response.success == true,
              let tracks = response.data, !tracks.isEmpty else { return nil }
        // Closest duration first; the list is usually a single entry.
        let sorted = tracks.sorted {
            let a = abs(Double($0.duration ?? 0) - Double(durationSeconds ?? 0))
            let b = abs(Double($1.duration ?? 0) - Double(durationSeconds ?? 0))
            return a < b
        }
        for track in sorted {
            // Rich sync is enhanced LRC with per-word stamps; the LRC
            // parser strips the word stamps and keeps the line timing.
            if let rich = track.richSyncLyrics, !rich.isBlank {
                let lines = Self.parseLRC(rich)
                if !lines.isEmpty {
                    return Lyrics(synced: lines, plainText: track.plainLyrics.nilIfBlank, source: "SimpMusic")
                }
            }
            if let synced = track.syncedLyrics, !synced.isBlank {
                let lines = Self.parseLRC(synced)
                if !lines.isEmpty {
                    return Lyrics(synced: lines, plainText: track.plainLyrics.nilIfBlank, source: "SimpMusic")
                }
            }
            if let plain = track.plainLyrics, !plain.isBlank {
                return Lyrics(synced: nil, plainText: plain, source: "SimpMusic")
            }
        }
        return nil
    }

    // MARK: - LyricsPlus

    private struct LyricsPlusResponse: Decodable {
        var type: String?
        var lyrics: [LyricsPlusLine]?
    }

    private struct LyricsPlusLine: Decodable {
        var time: Int?
        var duration: Int?
        var text: String?
    }

    /// Public LyricsPlus mirrors, in the order the Android app tries them.
    private static let lyricsPlusHosts = [
        "https://lyricsplus.prjktla.my.id",
        "https://lyricsplus.atomix.one",
        "https://lyricsplus.binimum.org",
        "https://lyricsplus.prjktla.workers.dev",
        "https://lyricsplus-seven.vercel.app",
        "https://lyrics-plus-backend.vercel.app",
    ]

    private func lyricsPlus(track: Track) async -> Lyrics? {
        for host in Self.lyricsPlusHosts {
            guard let url = url(base: "\(host)/v2/lyrics/get", query: [
                ("title", track.title),
                ("artist", track.artistNames),
                ("duration", track.durationSeconds.map(String.init)),
                ("album", track.album?.title),
            ]), let data = await getJSON(url),
                  let response = try? JSONDecoder().decode(LyricsPlusResponse.self, from: data),
                  let rawLines = response.lyrics, !rawLines.isEmpty else { continue }
            var lines: [LyricsLine] = []
            let sorted = rawLines.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
            for (index, raw) in sorted.enumerated() {
                guard let text = raw.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                let start = raw.time ?? 0
                let end: Int
                if let duration = raw.duration, duration > 0 {
                    end = start + duration
                } else if index + 1 < sorted.count {
                    end = sorted[index + 1].time ?? (start + 5000)
                } else {
                    end = start + 5000
                }
                lines.append(LyricsLine(startMs: start, endMs: max(end, start), text: text))
            }
            if !lines.isEmpty {
                return Lyrics(synced: lines, plainText: lines.map(\.text).joined(separator: "\n"), source: "LyricsPlus")
            }
        }
        return nil
    }

    // MARK: - Unison

    private struct UnisonResponse: Decodable {
        var success: Bool?
        var data: UnisonEntry?
    }

    private struct UnisonEntry: Decodable {
        var lyrics: String?
        var format: String?
        var syncType: String?
    }

    private func unison(track: Track) async -> Lyrics? {
        guard let url = url(base: "https://unison.boidu.dev/lyrics", query: [
            ("song", track.title),
            ("artist", track.artistNames),
            ("album", track.album?.title),
            ("duration", track.durationSeconds.map(String.init)),
        ]), let data = await getJSON(url),
              let response = try? JSONDecoder().decode(UnisonResponse.self, from: data),
              response.success == true,
              let entry = response.data,
              let text = entry.lyrics, !text.isBlank else { return nil }
        if entry.format?.lowercased() == "ttml" {
            let lines = Self.parseTTML(text)
            if !lines.isEmpty {
                return Lyrics(synced: lines, plainText: lines.map(\.text).joined(separator: "\n"), source: "Unison")
            }
        }
        if entry.syncType?.lowercased() == "plain" {
            return Self.lyricsFromPlainText(text, source: "Unison")
        }
        let lines = Self.parseLRC(text)
        if !lines.isEmpty {
            return Lyrics(synced: lines, plainText: lines.map(\.text).joined(separator: "\n"), source: "Unison")
        }
        return Self.lyricsFromPlainText(text, source: "Unison")
    }

    /// Plain-text fallback: a non-blank string becomes unsynced lyrics,
    /// a blank one becomes `nil` (no lyrics at all).
    static func lyricsFromPlainText(_ text: String, source: String) -> Lyrics? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Lyrics(synced: nil, plainText: trimmed, source: source)
    }

    // MARK: - Bini

    private struct BiniSearchResponse: Decodable {
        var results: [BiniHit]?
    }

    private struct BiniHit: Decodable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Int?
        var isrc: String?
        var timingType: String?
        var lyricsUrl: String?
    }

    private func bini(track: Track) async -> Lyrics? {
        let shaped: [(String, String?)] = [
            ("track", track.title),
            ("artist", track.artistNames),
            ("album", track.album?.title),
            ("duration", track.durationSeconds.map(String.init)),
        ]
        let freeText: [(String, String?)] = [
            ("q", "\(track.artistNames) - \(track.title)"),
        ]
        for query in [shaped, freeText] {
            guard let url = url(base: "https://lyrics-api.binimum.org/", query: query),
                  let data = await getJSON(url) else { continue }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let response = try? decoder.decode(BiniSearchResponse.self, from: data),
                  let hits = response.results, !hits.isEmpty else { continue }
            let best = hits
                .filter { Self.sameVersion(track.title, $0.trackName ?? "") }
                .map { hit -> (hit: BiniHit, score: Int) in
                    var score = 0
                    if Self.titlesMatch(hit.trackName ?? "", track.title) { score += 3 }
                    if Self.artistMatches(hit.artistName ?? "", track.artistNames) { score += 3 }
                    if hit.timingType?.lowercased() == "word" { score += 1 }
                    if let duration = hit.duration, let wanted = track.durationSeconds {
                        score -= min(abs(duration - wanted) / 10, 3)
                    }
                    return (hit, score)
                }
                .filter { $0.score >= 3 }
                .sorted { $0.score > $1.score }
                .first?.hit
            guard let best, let documentURL = best.lyricsUrl.flatMap(URL.init(string:)) else { continue }
            guard let document = await getText(documentURL) else { continue }
            let lines: [LyricsLine]
            if document.contains("<tt") || document.contains("xmlns=\"http://www.w3.org/ns/ttml\"") {
                lines = Self.parseTTML(document)
            } else {
                lines = Self.parseLRC(document)
            }
            if !lines.isEmpty {
                return Lyrics(synced: lines, plainText: lines.map(\.text).joined(separator: "\n"), source: "Bini")
            }
        }
        return nil
    }

    // MARK: - LRC parsing

    /// Parses LRC text (line-stamped and enhanced/word-stamped) into
    /// `LyricsLine`s. A line may carry several `[mm:ss.xx]` tags — one
    /// `LyricsLine` is produced per tag with the same text. Metadata tags
    /// (`[ti:]`, `[ar:]`, …) are ignored; `[offset:+123]` shifts every
    /// timestamp. Word stamps (`<mm:ss.xx>`) are stripped, keeping the
    /// line text. `endMs` is the next line's start, or start + 5 s for the
    /// last line.
    static func parseLRC(_ text: String) -> [LyricsLine] {
        let timestampPattern = #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        let offsetPattern = #"\[offset:\s*([+-]?\d+)\]"#
        let wordStampPattern = #"<\d{1,2}:\d{2}(?:[.:]\d{1,3})?>"#
        guard let timestampRegex = try? NSRegularExpression(pattern: timestampPattern),
              let offsetRegex = try? NSRegularExpression(pattern: offsetPattern),
              let wordStampRegex = try? NSRegularExpression(pattern: wordStampPattern) else {
            return []
        }

        var offsetMs = 0
        let fullRange = NSRange(text.startIndex..., in: text)
        if let offsetMatch = offsetRegex.firstMatch(in: text, range: fullRange),
           let range = Range(offsetMatch.range(at: 1), in: text),
           let value = Int(text[range]) {
            offsetMs = value
        }

        var parsed: [(startMs: Int, text: String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let lineRange = NSRange(rawLine.startIndex..., in: rawLine)
            let matches = timestampRegex.matches(in: rawLine, range: lineRange)
            guard !matches.isEmpty else { continue }
            guard let lastMatch = matches.last,
                  let textRange = Range(NSRange(location: lastMatch.range.upperBound, length: lineRange.length - lastMatch.range.upperBound), in: rawLine) else {
                continue
            }
            var lineText = String(rawLine[textRange])
            lineText = wordStampRegex.stringByReplacingMatches(
                in: lineText, range: NSRange(lineText.startIndex..., in: lineText), withTemplate: "")
            lineText = lineText.trimmingCharacters(in: .whitespaces)
            guard !lineText.isEmpty else { continue }
            for match in matches {
                guard let minutesRange = Range(match.range(at: 1), in: rawLine),
                      let secondsRange = Range(match.range(at: 2), in: rawLine),
                      let minutes = Int(rawLine[minutesRange]),
                      let seconds = Int(rawLine[secondsRange]) else { continue }
                var ms = (minutes * 60 + seconds) * 1000
                if match.range(at: 3).location != NSNotFound,
                   let fractionRange = Range(match.range(at: 3), in: rawLine) {
                    let fraction = String(rawLine[fractionRange])
                    if let value = Int(fraction) {
                        switch fraction.count {
                        case 1: ms += value * 100
                        case 2: ms += value * 10
                        default: ms += value
                        }
                    }
                }
                parsed.append((startMs: ms + offsetMs, text: lineText))
            }
        }
        parsed.sort { $0.startMs < $1.startMs }
        return parsed.enumerated().map { index, entry in
            let end = index + 1 < parsed.count ? parsed[index + 1].startMs : entry.startMs + 5000
            return LyricsLine(startMs: entry.startMs, endMs: max(end, entry.startMs), text: entry.text)
        }
    }

    // MARK: - TTML parsing

    /// Minimal TTML parser for the Apple-style timed-text documents served
    /// by Unison and Bini: reads `<p begin="…" end="…">text</p>` elements,
    /// strips inner tags and decodes the common XML entities. Times may be
    /// `mm:ss.cc`, `hh:mm:ss.cc` or plain seconds with an `s` suffix.
    static func parseTTML(_ text: String) -> [LyricsLine] {
        guard let paragraphRegex = try? NSRegularExpression(
            pattern: #"<p\b([^>]*)>(.*?)</p>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let beginRegex = try? NSRegularExpression(pattern: #"begin="([^"]+)""#),
              let endRegex = try? NSRegularExpression(pattern: #"end="([^"]+)""#),
              let tagRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        var parsed: [(startMs: Int, endMs: Int?, text: String)] = []
        for match in paragraphRegex.matches(in: text, range: fullRange) {
            guard let attrsRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { continue }
            let attrs = String(text[attrsRange])
            let attrsNSRange = NSRange(attrs.startIndex..., in: attrs)
            guard let beginMatch = beginRegex.firstMatch(in: attrs, range: attrsNSRange),
                  let beginRange = Range(beginMatch.range(at: 1), in: attrs),
                  let startMs = parseTTMLTime(String(attrs[beginRange])) else { continue }
            var endMs: Int?
            if let endMatch = endRegex.firstMatch(in: attrs, range: attrsNSRange),
               let endRange = Range(endMatch.range(at: 1), in: attrs) {
                endMs = parseTTMLTime(String(attrs[endRange]))
            }
            var body = String(text[bodyRange])
            body = tagRegex.stringByReplacingMatches(
                in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
            body = decodeXMLEntities(body).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            parsed.append((startMs: startMs, endMs: endMs, text: body))
        }
        parsed.sort { $0.startMs < $1.startMs }
        return parsed.enumerated().map { index, entry in
            let end: Int
            if let explicit = entry.endMs, explicit > entry.startMs {
                end = explicit
            } else if index + 1 < parsed.count {
                end = parsed[index + 1].startMs
            } else {
                end = entry.startMs + 5000
            }
            return LyricsLine(startMs: entry.startMs, endMs: max(end, entry.startMs), text: entry.text)
        }
    }

    static func parseTTMLTime(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains(":") {
            // Plain seconds, with or without the "s" suffix.
            let numeric = trimmed.hasSuffix("s") ? String(trimmed.dropLast()) : trimmed
            guard let seconds = Double(numeric) else { return nil }
            return Int(seconds * 1000)
        }
        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondsPart = parts.last!
        let secondsComponents = secondsPart.split(separator: ".")
        guard let seconds = Int(secondsComponents[0]) else { return nil }
        var ms = seconds * 1000
        if secondsComponents.count == 2, let fraction = Int(secondsComponents[1]) {
            switch secondsComponents[1].count {
            case 1: ms += fraction * 100
            case 2: ms += fraction * 10
            default: ms += fraction
            }
        }
        if parts.count == 3 {
            guard let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
            ms += (hours * 3600 + minutes * 60) * 1000
        } else {
            guard let minutes = Int(parts[0]) else { return nil }
            ms += minutes * 60 * 1000
        }
        return ms
    }

    private static func decodeXMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    // MARK: - Title / artist matching (ported from the Android LRCLIB code)

    /// Strips credits and packaging from a track title. Version markers
    /// (remix, live, acoustic…) name a different recording and must survive
    /// cleaning so `sameVersion` can reject the wrong cut.
    static func cleanTrackTitle(_ raw: String) -> String {
        var out = raw
        out = out.replacingOccurrences(of: #"(?i)\s*[\(\[](?:feat\.?|ft\.?|featuring|with)[^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+.*$"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\s*[\(\[]\s*(?:official\s*)?(?:music\s*)?(?:video|audio|visualizer|lyrics?\s*video|lyrics?|m/?v|hd|hq|4k|full\s*song)\s*[\)\]]"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\s*[\(\[]\s*official\s*[\)\]]"#, with: "", options: .regularExpression)
        let collapsed = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return collapsed.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : collapsed
    }

    static func cleanArtistName(_ raw: String) -> String {
        var out = raw
        out = out.replacingOccurrences(of: #"(?i)\s*[\(\[](?:feat\.?|ft\.?)[^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\s*(?:feat\.?|ft\.?)\s+.*$"#, with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func titlesMatch(_ candidate: String, _ request: String) -> Bool {
        let a = candidate.trimmingCharacters(in: .whitespaces)
        let b = request.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a.caseInsensitiveCompare(b) == .orderedSame { return true }
        if a.range(of: b, options: .caseInsensitive) != nil || b.range(of: a, options: .caseInsensitive) != nil {
            let ratio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
            if ratio >= 0.7 { return true }
        }
        return tokenOverlap(a, b) >= 0.5
    }

    static func artistMatches(_ candidate: String, _ request: String) -> Bool {
        let a = candidate.trimmingCharacters(in: .whitespaces)
        let b = request.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a.caseInsensitiveCompare(b) == .orderedSame { return true }
        if a.range(of: b, options: .caseInsensitive) != nil || b.range(of: a, options: .caseInsensitive) != nil {
            if min(a.count, b.count) < 4 { return tokenOverlap(a, b) >= 0.5 }
            let ratio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
            if ratio >= 0.6 { return true }
        }
        return tokenOverlap(a, b) >= 0.5
    }

    private static func tokenOverlap(_ a: String, _ b: String) -> Double {
        let aTokens = Set(a.lowercased().split(separator: " ").map(String.init))
        let bTokens = Set(b.lowercased().split(separator: " ").map(String.init))
        let union = aTokens.union(bTokens)
        guard !union.isEmpty else { return 0 }
        return Double(aTokens.intersection(bTokens).count) / Double(union.count)
    }

    private static let versionKeywords: [String: String] = [
        "live": "live", "concert": "live", "session": "live",
        "unplugged": "unplugged", "acoustic": "acoustic",
        "remix": "remix", "cover": "cover", "karaoke": "karaoke",
        "instrumental": "instrumental", "slowed": "slowed",
        "sped up": "sped", "speed up": "sped", "spedup": "sped",
        "sped": "sped", "nightcore": "sped", "demo": "demo",
        "lullaby": "lullaby", "8d": "8d",
    ]

    /// Version tags found in brackets or a trailing "- X" suffix.
    static func versionTags(of title: String) -> Set<String> {
        var segments: [String] = []
        if let regex = try? NSRegularExpression(pattern: #"[\(\[](.*?)[\)\]]"#) {
            let range = NSRange(title.startIndex..., in: title)
            for match in regex.matches(in: title, range: range) {
                if let r = Range(match.range(at: 1), in: title) {
                    segments.append(String(title[r]))
                }
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"\s*[-–—:]\s*([^-–—:\(\[]+)\s*$"#) {
            let range = NSRange(title.startIndex..., in: title)
            if let match = regex.firstMatch(in: title, range: range),
               let r = Range(match.range(at: 1), in: title) {
                segments.append(String(title[r]))
            }
        }
        var tags = Set<String>()
        for segment in segments {
            let lower = " \(segment.lowercased()) "
            for (keyword, tag) in versionKeywords where lower.contains(keyword) {
                tags.insert(tag)
            }
        }
        return tags
    }

    /// True only when both titles describe the same recording version.
    static func sameVersion(_ requestTitle: String, _ candidateTitle: String) -> Bool {
        versionTags(of: requestTitle) == versionTags(of: candidateTitle)
    }
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension Optional where Wrapped == String {
    var isNilOrBlank: Bool {
        switch self {
        case .none: return true
        case .some(let value): return value.isBlank
        }
    }

    var nilIfBlank: String? {
        switch self {
        case .none: return nil
        case .some(let value): return value.isBlank ? nil : value
        }
    }
}
