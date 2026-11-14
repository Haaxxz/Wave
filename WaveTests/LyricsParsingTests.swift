import XCTest

@testable import Wave

// MARK: - Lyrics parsing tests
//
// No network: every test feeds literal LRC / TTML / plain text into the
// static parsers on `LyricsProvider`.

final class LyricsParsingTests: XCTestCase {
    func testLRCBasic() {
        let lines = LyricsProvider.parseLRC("[00:12.00]Hello\n[00:15.50]World\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].startMs, 12000)
        XCTAssertEqual(lines[0].endMs, 15500)
        XCTAssertEqual(lines[0].text, "Hello")
        XCTAssertEqual(lines[1].startMs, 15500)
        XCTAssertEqual(lines[1].endMs, 20500)
        XCTAssertEqual(lines[1].text, "World")
    }

    func testLRCMultipleTimestampsPerLine() {
        let lines = LyricsProvider.parseLRC("[00:10.00][00:20.00]Chorus line\n[00:30.00]Next\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].startMs, 10000)
        XCTAssertEqual(lines[0].endMs, 20000)
        XCTAssertEqual(lines[1].startMs, 20000)
        XCTAssertEqual(lines[1].endMs, 30000)
        XCTAssertEqual(lines[2].startMs, 30000)
        XCTAssertTrue(lines[0].text == "Chorus line" && lines[1].text == "Chorus line")
    }

    func testLRCMetadataTagsIgnored() {
        let text = """
        [ti:Song Title]
        [ar:Some Artist]
        [al:Some Album]
        [by:Someone]
        [length:03:30]
        [00:01.00]First line
        """
        let lines = LyricsProvider.parseLRC(text)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "First line")
        XCTAssertEqual(lines[0].startMs, 1000)
    }

    func testLRCOffset() {
        let lines = LyricsProvider.parseLRC("[offset:+1000]\n[00:01.00]Shifted\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].startMs, 2000)
        let negative = LyricsProvider.parseLRC("[offset:-500]\n[00:01.00]Shifted\n")
        XCTAssertEqual(negative[0].startMs, 500)
    }

    func testLRCWordStampsStripped() {
        let lines = LyricsProvider.parseLRC("[00:01.00]Hel<00:01.50>lo <00:02.00>world\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Hello world")
        XCTAssertEqual(lines[0].startMs, 1000)
    }

    func testLRCFractionFormats() {
        XCTAssertEqual(LyricsProvider.parseLRC("[00:01.5]A\n")[0].startMs, 1500)
        XCTAssertEqual(LyricsProvider.parseLRC("[00:01.50]A\n")[0].startMs, 1500)
        XCTAssertEqual(LyricsProvider.parseLRC("[00:01.500]A\n")[0].startMs, 1500)
        XCTAssertEqual(LyricsProvider.parseLRC("[00:01:250]A\n")[0].startMs, 1250)
        XCTAssertEqual(LyricsProvider.parseLRC("[01:02]A\n")[0].startMs, 62000)
        XCTAssertEqual(LyricsProvider.parseLRC("[00:01:00]A\n")[0].startMs, 1000)
    }

    func testLRCEmptyAndMalformed() {
        XCTAssertTrue(LyricsProvider.parseLRC("").isEmpty)
        XCTAssertTrue(LyricsProvider.parseLRC("Just plain text\nNo timestamps here\n").isEmpty)
        XCTAssertTrue(LyricsProvider.parseLRC("[00:01.00]\n").isEmpty, "a timestamp with no text is not a line")
        XCTAssertTrue(LyricsProvider.parseLRC("[00:01.00]   \n").isEmpty)
        XCTAssertTrue(LyricsProvider.parseLRC("[ti:Title]\n").isEmpty)
    }

    func testLRCLinesAreSorted() {
        let lines = LyricsProvider.parseLRC("[00:30.00]Third\n[00:10.00]First\n[00:20.00]Second\n")
        XCTAssertEqual(lines.map(\.text), ["First", "Second", "Third"])
        XCTAssertEqual(lines.map(\.startMs), [10000, 20000, 30000])
    }

    func testLyricsLineAtPosition() {
        let lyrics = Lyrics(
            synced: LyricsProvider.parseLRC("[00:10.00]One\n[00:20.00]Two\n"),
            plainText: nil,
            source: "test"
        )
        XCTAssertEqual(lyrics.line(at: 5000)?.text, nil)
        XCTAssertEqual(lyrics.line(at: 10000)?.text, "One")
        XCTAssertEqual(lyrics.line(at: 19999)?.text, "One")
        XCTAssertEqual(lyrics.line(at: 20000)?.text, "Two")
    }

    func testTTMLBasic() {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
        <p begin="00:00:01.000" end="00:00:03.000">Hello</p>
        <p begin="00:00:03.000" end="00:00:05.500">World</p>
        </div></body></tt>
        """
        let lines = LyricsProvider.parseTTML(ttml)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].startMs, 1000)
        XCTAssertEqual(lines[0].endMs, 3000)
        XCTAssertEqual(lines[0].text, "Hello")
        XCTAssertEqual(lines[1].startMs, 3000)
        XCTAssertEqual(lines[1].endMs, 5500)
    }

    func testTTMLSecondsFormat() {
        XCTAssertEqual(LyricsProvider.parseTTMLTime("1.5s"), 1500)
        XCTAssertEqual(LyricsProvider.parseTTMLTime("83.5"), 83500)
        XCTAssertEqual(LyricsProvider.parseTTMLTime("01:02.3"), 62300)
        XCTAssertEqual(LyricsProvider.parseTTMLTime("01:02:03.25"), 3723250)
        XCTAssertNil(LyricsProvider.parseTTMLTime("not a time"))
        XCTAssertNil(LyricsProvider.parseTTMLTime(""))
    }

    func testTTMLInnerTagsStrippedAndEntitiesDecoded() {
        let ttml = #"<p begin="00:00:01.000" end="00:00:02.000">Hel<span>lo</span> &amp; goodbye</p>"#
        let lines = LyricsProvider.parseTTML(ttml)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Hello & goodbye")
    }

    func testTTMLMissingEndUsesNextStart() {
        let ttml = """
        <p begin="00:00:01.000">First</p>
        <p begin="00:00:04.000">Second</p>
        """
        let lines = LyricsProvider.parseTTML(ttml)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].endMs, 4000)
        XCTAssertEqual(lines[1].endMs, 9000)
    }

    func testPlainTextFallback() {
        let lyrics = LyricsProvider.lyricsFromPlainText("Line one\nLine two\n", source: "LRCLIB")
        XCTAssertNotNil(lyrics)
        XCTAssertNil(lyrics?.synced)
        XCTAssertEqual(lyrics?.plainText, "Line one\nLine two")
        XCTAssertEqual(lyrics?.source, "LRCLIB")
        XCTAssertNil(LyricsProvider.lyricsFromPlainText("   \n  ", source: "LRCLIB"))
        XCTAssertNil(LyricsProvider.lyricsFromPlainText("", source: "LRCLIB"))
        // Plain text has no timing, so the LRC parser must not claim it.
        XCTAssertTrue(LyricsProvider.parseLRC("Line one\nLine two\n").isEmpty)
    }

    func testTitleCleaning() {
        XCTAssertEqual(
            LyricsProvider.cleanTrackTitle("Shape of You (feat. Stormzy) [Official Video]"),
            "Shape of You"
        )
        XCTAssertEqual(
            LyricsProvider.cleanTrackTitle("Blinding Lights - Official Music Video"),
            "Blinding Lights - Official Music Video"
        )
        XCTAssertEqual(LyricsProvider.cleanArtistName("Ed Sheeran feat. Justin Bieber"), "Ed Sheeran")
        XCTAssertEqual(LyricsProvider.cleanArtistName("Taylor Swift"), "Taylor Swift")
    }

    func testVersionTags() {
        XCTAssertTrue(LyricsProvider.sameVersion("Song", "Song"))
        XCTAssertFalse(LyricsProvider.sameVersion("Song (Live)", "Song"))
        XCTAssertFalse(LyricsProvider.sameVersion("Song", "Song (Remix)"))
        XCTAssertTrue(LyricsProvider.sameVersion("Song (Live)", "Song (Live)"))
        XCTAssertTrue(LyricsProvider.sameVersion("Song - Acoustic", "Song (Acoustic)"))
    }

    func testTitleAndArtistMatching() {
        XCTAssertTrue(LyricsProvider.titlesMatch("Shape of You", "Shape of You"))
        XCTAssertTrue(LyricsProvider.titlesMatch("Shape Of You", "shape of you"))
        XCTAssertFalse(LyricsProvider.titlesMatch("Love", "Love Me Like You Do"))
        XCTAssertTrue(LyricsProvider.artistMatches("Ed Sheeran", "Ed Sheeran"))
        XCTAssertTrue(LyricsProvider.artistMatches("Ed Sheeran", "Sheeran"))
        XCTAssertFalse(LyricsProvider.artistMatches("Ann", "Annie"))
    }
}
