import XCTest

@testable import Wave

// MARK: - Audio tag writer tests
//
// Verifies the ID3v2.3 writer byte-for-byte (header magic, version, frame
// ids) and the `.lrc` sidecar format. No network is involved; tags are
// written to files in a temporary directory.

final class AudioTagWriterTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testBuildID3v2TagHeaderBytes() {
        let tag = AudioTagWriter.buildID3v2Tag(
            title: "Test Song",
            artist: "Test Artist",
            album: "Test Album",
            trackNumber: 3,
            artworkData: nil,
            lyricsText: nil,
            year: nil
        )
        // "ID3" magic + version 2.3.0 + flags 0.
        XCTAssertEqual(Array(tag.prefix(3)), [0x49, 0x44, 0x33])
        XCTAssertEqual(tag[3], 0x03)
        XCTAssertEqual(tag[4], 0x00)
        XCTAssertEqual(tag[5], 0x00)
        // Synchsafe size must match the frame payload that follows.
        let size = (Int(tag[6]) << 21) | (Int(tag[7]) << 14) | (Int(tag[8]) << 7) | Int(tag[9])
        XCTAssertEqual(size, tag.count - 10)
        // Frame ids are present, in order.
        let bytes = [UInt8](tag)
        XCTAssertTrue(containsFrame(bytes, id: "TIT2"))
        XCTAssertTrue(containsFrame(bytes, id: "TPE1"))
        XCTAssertTrue(containsFrame(bytes, id: "TPE2"))
        XCTAssertTrue(containsFrame(bytes, id: "TALB"))
        XCTAssertTrue(containsFrame(bytes, id: "TRCK"))
        // The title is stored as UTF-16LE with BOM (encoding byte 0x01).
        let titleUTF16 = utf16LEWithBOM("Test Song")
        XCTAssertTrue(containsBytes(bytes, titleUTF16))
        // The track number is stored as the text "3".
        let trackUTF16 = utf16LEWithBOM("3")
        XCTAssertTrue(containsBytes(bytes, trackUTF16))
    }

    func testBuildID3v2TagWithArtworkAndLyrics() {
        // Minimal 1x1 PNG (signature + IHDR only; the writer only sniffs it).
        let png: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        ]
        let tag = AudioTagWriter.buildID3v2Tag(
            title: "Song",
            artist: "Artist",
            album: nil,
            trackNumber: nil,
            artworkData: Data(png),
            lyricsText: "la la la",
            year: nil
        )
        let bytes = [UInt8](tag)
        XCTAssertTrue(containsFrame(bytes, id: "USLT"))
        XCTAssertTrue(containsFrame(bytes, id: "APIC"))
        XCTAssertTrue(containsBytes(bytes, Array("image/png".utf8)))
        XCTAssertTrue(containsBytes(bytes, png))
        // Lyrics are UTF-16LE with BOM inside the USLT frame.
        XCTAssertTrue(containsBytes(bytes, utf16LEWithBOM("la la la")))
    }

    func testWriteTagsToSyntheticMP3File() throws {
        let track = Track(
            id: "vid-1",
            title: "Tagged Song",
            artists: [ArtistRef(id: "a1", name: "Tagged Artist")],
            album: AlbumRef(id: "al1", title: "Tagged Album")
        )
        let fileURL = tempDir.appendingPathComponent("Tagged Artist - Tagged Song.mp3")
        // A synthetic "MP3": 1 KB of audio payload bytes (no real frames).
        try Data(repeating: 0xAA, count: 1024).write(to: fileURL)

        try AudioTagWriter.writeTags(track: track, to: fileURL)

        let tagged = try Data(contentsOf: fileURL)
        XCTAssertGreaterThan(tagged.count, 1024)
        XCTAssertEqual(Array(tagged.prefix(3)), [0x49, 0x44, 0x33])
        XCTAssertEqual(tagged[3], 0x03)
        XCTAssertEqual(tagged[4], 0x00)
        let bytes = [UInt8](tagged)
        XCTAssertTrue(containsFrame(bytes, id: "TIT2"))
        XCTAssertTrue(containsBytes(bytes, utf16LEWithBOM("Tagged Song")))
        XCTAssertTrue(containsBytes(bytes, utf16LEWithBOM("Tagged Artist")))
        XCTAssertTrue(containsBytes(bytes, utf16LEWithBOM("Tagged Album")))
        // The original payload survives after the tag.
        XCTAssertEqual(Array(tagged.suffix(16)), Array(repeating: 0xAA, count: 16))
    }

    func testWriteTagsReplacesExistingID3Tag() throws {
        let track = Track(id: "vid-2", title: "New Title", artists: [ArtistRef(id: "a1", name: "Artist")])
        let fileURL = tempDir.appendingPathComponent("song.mp3")
        let oldTag = AudioTagWriter.buildID3v2Tag(
            title: "Old Title", artist: "Artist", album: nil,
            trackNumber: nil, artworkData: nil, lyricsText: nil, year: nil
        )
        var file = oldTag
        file.append(Data(repeating: 0xBB, count: 512))
        try file.write(to: fileURL)

        try AudioTagWriter.writeTags(track: track, to: fileURL)

        let tagged = try Data(contentsOf: fileURL)
        let bytes = [UInt8](tagged)
        XCTAssertTrue(containsBytes(bytes, utf16LEWithBOM("New Title")))
        XCTAssertFalse(containsBytes(bytes, utf16LEWithBOM("Old Title")))
        XCTAssertEqual(Array(tagged.suffix(8)), Array(repeating: 0xBB, count: 8))
    }

    func testWriteLyricsSidecar() throws {
        let track = Track(
            id: "vid-3",
            title: "Synced Song",
            artists: [ArtistRef(id: "a1", name: "Singer")]
        )
        let lyrics = Lyrics(
            synced: [
                LyricsLine(startMs: 0, endMs: 2_000, text: "First line"),
                LyricsLine(startMs: 62_340, endMs: 65_000, text: "Second line"),
            ],
            plainText: "First line\nSecond line",
            source: "LRCLIB"
        )
        try AudioTagWriter.writeLyricsSidecar(track: track, lyrics: lyrics, to: tempDir)

        let sidecar = tempDir
            .appendingPathComponent("Singer - Synced Song")
            .appendingPathExtension("lrc")
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(text.contains("[00:00.00]First line"))
        XCTAssertTrue(text.contains("[01:02.34]Second line"))
    }

    func testSanitizeFileName() {
        XCTAssertEqual(AudioTagWriter.sanitizeFileName("A/B: C*D?"), "A_B_ C_D_")
        XCTAssertEqual(AudioTagWriter.sanitizeFileName("  "), "Unknown")
        XCTAssertEqual(AudioTagWriter.sanitizeFileName("Normal Name"), "Normal Name")
    }

    // MARK: - Helpers

    private func containsFrame(_ bytes: [UInt8], id: String) -> Bool {
        containsBytes(bytes, Array(id.utf8))
    }

    private func containsBytes(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return true
            }
        }
        return false
    }

    private func utf16LEWithBOM(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = [0xFF, 0xFE]
        for unit in text.utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8((unit >> 8) & 0xFF))
        }
        return bytes
    }
}
