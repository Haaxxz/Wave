import XCTest
@testable import Wave

// MARK: - InnerTube parsing tests
//
// No network: every test runs against the hand-made fixtures in
// WaveTests/Fixtures, which match real InnerTube response shapes.

final class InnerTubeParsingTests: XCTestCase {

    private func fixtureJSON(named name: String) throws -> JSONValue {
        if let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "json") {
            return try JSONValue(data: Data(contentsOf: url))
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "json") {
            return try JSONValue(data: Data(contentsOf: url))
        }
        // Source-tree fallback: the test bundle runs from a checkout, so
        // the fixture files exist on disk next to this test file.
        let testFile = URL(fileURLWithPath: #file)
        let fixtureURL = testFile.deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try JSONValue(data: Data(contentsOf: fixtureURL))
    }

    // MARK: - Scalars

    func testParseDuration() {
        XCTAssertEqual(InnerTubeParsing.parseDuration("3:24"), 204)
        XCTAssertEqual(InnerTubeParsing.parseDuration("1:02:03"), 3723)
        XCTAssertEqual(InnerTubeParsing.parseDuration("0:45"), 45)
        XCTAssertNil(InnerTubeParsing.parseDuration("abc"))
        XCTAssertNil(InnerTubeParsing.parseDuration("2020"))
        XCTAssertNil(InnerTubeParsing.parseDuration("3"))
        XCTAssertNil(InnerTubeParsing.parseDuration("1:2:3:4"))
    }

    func testHighResolutionArtwork() {
        XCTAssertEqual(
            InnerTubeParsing.highResolutionArtwork("https://lh3.googleusercontent.com/abc=w60-h60-l90-rj"),
            "https://lh3.googleusercontent.com/abc=w1200-h1200-l90-rj"
        )
        XCTAssertEqual(
            InnerTubeParsing.highResolutionArtwork("//lh3.googleusercontent.com/abc=w60-h60-l90-rj"),
            "https://lh3.googleusercontent.com/abc=w1200-h1200-l90-rj"
        )
        XCTAssertEqual(
            InnerTubeParsing.highResolutionArtwork("https://i.ytimg.com/vi/abc/hqdefault.jpg"),
            "https://i.ytimg.com/vi/abc/hqdefault.jpg"
        )
    }

    func testYoutubeText() throws {
        let runs = try JSONValue(data: #"{"runs": [{"text": "Mid"}, {"text": "night"}]}"#.data(using: .utf8)!)
        XCTAssertEqual(runs.text, "Midnight")
        let simple = try JSONValue(data: #"{"simpleText": "Hello"}"#.data(using: .utf8)!)
        XCTAssertEqual(simple.text, "Hello")
        let plain = try JSONValue(data: #""Just text""#.data(using: .utf8)!)
        XCTAssertEqual(plain.text, "Just text")
    }

    func testIsLikelyArtist() {
        XCTAssertTrue(InnerTubeParsing.isLikelyArtist("M83"))
        XCTAssertTrue(InnerTubeParsing.isLikelyArtist("The Weeknd"))
        XCTAssertFalse(InnerTubeParsing.isLikelyArtist("15M monthly listeners"))
        XCTAssertFalse(InnerTubeParsing.isLikelyArtist("3:24"))
        XCTAssertFalse(InnerTubeParsing.isLikelyArtist("2020"))
        XCTAssertFalse(InnerTubeParsing.isLikelyArtist("•"))
        XCTAssertFalse(InnerTubeParsing.isLikelyArtist("Album"))
        XCTAssertFalse(InnerTubeParsing.isLikelyArtist("42 songs"))
    }

    // MARK: - Home feed

    func testHomeFeedSections() throws {
        let root = try fixtureJSON(named: "home-browse")
        let sections = InnerTubeParsing.parseFeedSections(in: root)
        XCTAssertEqual(sections.count, 2)

        let quickPicks = sections[0]
        XCTAssertEqual(quickPicks.title, "Quick picks")
        XCTAssertEqual(quickPicks.browseId, "FEmusic_home")
        XCTAssertEqual(quickPicks.items.count, 2)

        guard case .track(let song) = quickPicks.items[0] else {
            XCTFail("First quick-picks item should be a track")
            return
        }
        XCTAssertEqual(song.id, "dQw4w9WgXcQ")
        XCTAssertEqual(song.title, "Midnight City")
        XCTAssertEqual(song.artists.map(\.name), ["M83"])
        XCTAssertEqual(song.artists.first?.id, "UC1234567890")
        XCTAssertEqual(song.album?.title, "Hurry Up, We're Dreaming")
        XCTAssertEqual(song.album?.id, "MPREb_abcdef")
        XCTAssertEqual(song.durationSeconds, 243)
        // The 540px thumbnail URL is rewritten to the 1200px form.
        XCTAssertTrue(song.thumbnails.contains {
            $0.url?.absoluteString.contains("=w1200-h1200-l90-rj") == true
        })

        guard case .album(let album) = quickPicks.items[1] else {
            XCTFail("Second quick-picks item should be an album")
            return
        }
        XCTAssertEqual(album.id, "MPREb_xyz123")
        XCTAssertEqual(album.title, "Random Access Memories")

        let topSongs = sections[1]
        XCTAssertEqual(topSongs.title, "Top songs")
        XCTAssertEqual(topSongs.items.count, 1)
        guard case .track(let top) = topSongs.items[0] else {
            XCTFail("Top-songs item should be a track")
            return
        }
        XCTAssertEqual(top.id, "fHI8X4OXluQ")
        XCTAssertEqual(top.title, "Blinding Lights")
        XCTAssertEqual(top.artists.map(\.name), ["The Weeknd"])
        XCTAssertEqual(top.album?.title, "After Hours")
        XCTAssertEqual(top.durationSeconds, 200)
    }

    // MARK: - Search

    func testSearchResults() throws {
        let root = try fixtureJSON(named: "search")
        let results = InnerTubeParsing.parseSearchResults(from: root)

        XCTAssertEqual(results.songs.count, 1)
        XCTAssertEqual(results.songs.first?.id, "fHI8X4OXluQ")
        XCTAssertEqual(results.songs.first?.title, "Blinding Lights")

        XCTAssertEqual(results.artists.count, 1)
        XCTAssertEqual(results.artists.first?.id, "UC987654321")
        XCTAssertEqual(results.artists.first?.name, "M83")

        XCTAssertEqual(results.albums.count, 1)
        XCTAssertEqual(results.albums.first?.id, "MPREb_abcdef")
        XCTAssertEqual(results.albums.first?.title, "Hurry Up, We're Dreaming")

        XCTAssertEqual(results.playlists.count, 1)
        XCTAssertEqual(results.playlists.first?.id, "PLmidnight1")
        XCTAssertEqual(results.playlists.first?.title, "Midnight Drive")

        XCTAssertTrue(results.videos.isEmpty)
    }

    // MARK: - Radio / queue order

    func testRadioTracksPreserveOrder() throws {
        let json = """
        {
          "continuationContents": {
            "playlistPanelContinuation": {
              "contents": [
                {"playlistPanelVideoRenderer": {"videoId": "aaa111aaa11", "title": {"runs": [{"text": "First"}]}, "shortBylineText": {"runs": [{"text": "One"}]}, "lengthText": {"runs": [{"text": "1:00"}]}}},
                {"playlistPanelVideoRenderer": {"videoId": "bbb222bbb22", "title": {"runs": [{"text": "Second"}]}, "shortBylineText": {"runs": [{"text": "Two"}]}, "lengthText": {"runs": [{"text": "2:00"}]}}},
                {"playlistPanelVideoRenderer": {"videoId": "ccc333ccc33", "title": {"runs": [{"text": "Third"}]}, "shortBylineText": {"runs": [{"text": "Three"}]}, "lengthText": {"runs": [{"text": "3:00"}]}}}
              ]
            }
          }
        }
        """
        let root = try JSONValue(data: Data(json.utf8))
        let tracks = InnerTubeParsing.parseRadioTracks(in: root)
        XCTAssertEqual(tracks.map(\.id), ["aaa111aaa11", "bbb222bbb22", "ccc333ccc33"])
        XCTAssertEqual(tracks.map(\.title), ["First", "Second", "Third"])
        XCTAssertEqual(tracks.map(\.durationSeconds), [60, 120, 180])
    }

    // MARK: - Player / streamingData

    func testStreamFormats() throws {
        let root = try fixtureJSON(named: "player")
        let parsed = InnerTubeParsing.parseStreamFormats(in: root)
        XCTAssertEqual(parsed.playabilityStatus, "OK")
        XCTAssertNil(parsed.reason)
        XCTAssertEqual(parsed.durationSeconds, 243)
        XCTAssertFalse(parsed.isLive)
        XCTAssertEqual(parsed.formats.count, 3)

        let audio = parsed.formats.filter { $0.mimeType.hasPrefix("audio/") }
        XCTAssertEqual(audio.count, 2)

        let opus = audio.first(where: { $0.itag == 251 })
        XCTAssertNotNil(opus?.url)
        XCTAssertNil(opus?.cipher)
        XCTAssertEqual(opus?.bitrate, 160_000)
        XCTAssertEqual(opus?.audioSampleRate, 48_000)
        XCTAssertEqual(opus?.approxDurationMs, 243_000)
        XCTAssertTrue(opus?.isAdaptive == true)

        let aac = audio.first(where: { $0.itag == 140 })
        XCTAssertNil(aac?.url)
        XCTAssertNotNil(aac?.cipher)
        XCTAssertEqual(aac?.bitrate, 128_000)

        let video = parsed.formats.first(where: { $0.itag == 18 })
        XCTAssertEqual(video?.isAdaptive, false)
    }

    func testCompatibleAudio() {
        XCTAssertTrue(InnerTubeParsing.isCompatibleAudio(mimeType: "audio/webm; codecs=\"opus\""))
        XCTAssertTrue(InnerTubeParsing.isCompatibleAudio(mimeType: "audio/mp4; codecs=\"mp4a.40.2\""))
        XCTAssertTrue(InnerTubeParsing.isCompatibleAudio(mimeType: "audio/mpeg"))
        XCTAssertFalse(InnerTubeParsing.isCompatibleAudio(mimeType: "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\""))
        XCTAssertFalse(InnerTubeParsing.isCompatibleAudio(mimeType: "audio/webm; codecs=\"vp9\""))
        XCTAssertEqual(InnerTubeParsing.codec(from: "audio/webm; codecs=\"opus\""), "opus")
        XCTAssertEqual(InnerTubeParsing.codec(from: "audio/mp4; codecs=\"mp4a.40.2\""), "mp4a.40.2")
    }

    func testAppendingPoToken() {
        let url = "https://rr1---sn-abc.googlevideo.com/videoplayback?expire=1&itag=251"
        let withToken = InnerTubeParsing.appendingPoToken(to: url, token: "sessiontoken123")
        XCTAssertTrue(withToken.contains("pot=sessiontoken123"))
        XCTAssertTrue(withToken.contains("expire=1"))
        // Non-googlevideo URLs are left alone.
        XCTAssertEqual(
            InnerTubeParsing.appendingPoToken(to: "https://example.com/audio.mp3", token: "x"),
            "https://example.com/audio.mp3"
        )
    }

    func testDrcDetection() {
        XCTAssertTrue(InnerTubeParsing.isDrcAudioURL("https://example.googlevideo.com/v?xtags=foo%3Ddrc%3D1%26bar"))
        XCTAssertTrue(InnerTubeParsing.isDrcAudioURL("https://example.googlevideo.com/v?xtags=drc=1"))
        XCTAssertFalse(InnerTubeParsing.isDrcAudioURL("https://example.googlevideo.com/v?xtags=drc%3D0"))
        XCTAssertFalse(InnerTubeParsing.isDrcAudioURL("https://example.googlevideo.com/v?itag=251"))
    }
}
