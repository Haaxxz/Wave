import AVFoundation
import Foundation

// MARK: - Audio tag writer
//
// Embeds metadata (title, artist, album, cover art, lyrics) into a downloaded
// audio file, using the writer each container actually understands — ported
// from the Android app's AudioTagWriter:
//
//  - MP3 / unknown containers -> ID3v2.3 prepend (TIT2/TPE1/TPE2/TALB/TRCK/
//    TYER/USLT/APIC). Text frames use UTF-16LE with BOM (encoding 0x01);
//    UTF-8 (0x03) is illegal in v2.3 and makes strict readers drop the frames.
//  - FLAC -> native Vorbis comments + PICTURE metadata block (rewrites the
//    metadata chain; FLAC frames carry absolute sample positions, so inserting
//    blocks cannot corrupt playback). A leading ID3 chunk would break strict
//    FLAC parsers, so it is never used here.
//  - M4A -> AVFoundation `AVAssetExportSession` (passthrough) with native
//    iTunes metadata items. AVFoundation cannot write FLAC tags, which is
//    why FLAC has the native writer above.
//  - WebM / Ogg Opus -> left untouched. The native Matroska/Ogg writers from
//    the Android app were not ported; downloads prefer audio/mp4 (m4a) when
//    available, so this path is rare. The file keeps its name and .lrc sidecar.
//
// Every writer validates its output in a temp file before atomically
// replacing the original — any anomaly leaves the audio untouched. Tagging
// is best-effort: callers catch errors and keep the (untagged) download.

enum AudioTagError: Error, LocalizedError {
    case unsupportedContainer
    case exportFailed(String)
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedContainer: return "Audio container does not support tagging"
        case .exportFailed(let message): return "Metadata export failed: \(message)"
        case .ioError(let message): return "Tag I/O error: \(message)"
        }
    }
}

enum AudioTagWriter {
    /// Maximum embedded artwork size; a giant image must not balloon the file.
    static let maxArtworkBytes = 2 * 1024 * 1024

    /// Writes title/artist/album (and, when supplied, artwork, lyrics and a
    /// track number) into the file at `fileURL`. Throws
    /// `AudioTagError.unsupportedContainer` for WebM/Ogg, which callers treat
    /// as "leave the file untagged".
    static func writeTags(track: Track, to fileURL: URL) throws {
        try writeTags(track: track, to: fileURL, artworkData: nil, lyricsText: nil, trackNumber: nil)
    }

    /// Full entry point used by `DownloadManager`, which fetches the artwork
    /// and lyrics asynchronously before calling in.
    static func writeTags(
        track: Track,
        to fileURL: URL,
        artworkData: Data?,
        lyricsText: String?,
        trackNumber: Int?
    ) throws {
        let title = track.title
        let artist = track.artistNames
        let album = track.album?.title
        // Track carries no release year, so no TYER/DATE field is written.
        let year: String? = nil

        switch detectContainerKind(fileURL: fileURL) {
        case .flac:
            try embedIntoFLAC(
                fileURL: fileURL, title: title, artist: artist, album: album,
                artworkData: artworkData, lyricsText: lyricsText, year: year
            )
        case .mp4:
            try embedIntoM4A(
                fileURL: fileURL, title: title, artist: artist, album: album,
                artworkData: artworkData, lyricsText: lyricsText
            )
        case .other:
            try embedID3Prepend(
                fileURL: fileURL, title: title, artist: artist, album: album,
                artworkData: artworkData, lyricsText: lyricsText, year: year,
                trackNumber: trackNumber
            )
        case .webm, .ogg:
            throw AudioTagError.unsupportedContainer
        }
    }

    /// Writes a `.lrc` sidecar next to the audio file (same base name):
    /// `[mm:ss.cc]line` for synced lyrics, plain text lines otherwise.
    static func writeLyricsSidecar(track: Track, lyrics: Lyrics, to folder: URL) throws {
        let baseName = sanitizeFileName("\(track.artistNames) - \(track.title)")
        let sidecarURL = folder.appendingPathComponent(baseName).appendingPathExtension("lrc")
        var lines: [String] = []
        if let synced = lyrics.synced, !synced.isEmpty {
            for line in synced {
                let totalMs = max(0, line.startMs)
                let minutes = totalMs / 60_000
                let seconds = (totalMs / 1_000) % 60
                let centis = (totalMs % 1_000) / 10
                lines.append(String(format: "[%02d:%02d.%02d]%@", minutes, seconds, centis, line.text))
            }
        } else if let plain = lyrics.plainText, !plain.isEmpty {
            lines = plain.components(separatedBy: .newlines)
        } else {
            return
        }
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: sidecarURL, atomically: true, encoding: .utf8)
    }

    /// Replaces characters that are illegal in a file name with "_", trims
    /// trailing dots/spaces, and caps the length so the name stays usable.
    static func sanitizeFileName(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
        var cleaned = raw
            .components(separatedBy: illegal)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix(".") || cleaned.hasSuffix(" ") {
            cleaned.removeLast()
        }
        if cleaned.isEmpty { cleaned = "Unknown" }
        if cleaned.count > 200 { cleaned = String(cleaned.prefix(200)) }
        return cleaned
    }

    // MARK: Container detection

    private enum ContainerKind { case flac, mp4, webm, ogg, other }

    private static func detectContainerKind(fileURL: URL) -> ContainerKind {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return .other }
        defer { try? handle.close() }
        let id3Length = (try? existingID3Length(handle: handle)) ?? 0
        guard let header = try? handle.read(upToCount: 12), header.count >= 12 else { return .other }
        // Skip past a leading ID3v2 tag before sniffing the container.
        let bytes: [UInt8]
        if id3Length > 0 {
            try? handle.seek(toOffset: UInt64(id3Length))
            guard let sniffed = try? handle.read(upToCount: 12), sniffed.count >= 12 else { return .other }
            bytes = Array(sniffed)
        } else {
            bytes = Array(header)
        }
        if bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 { // fLaC
            return .flac
        }
        if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 { // ftyp
            return .mp4
        }
        if bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 { // EBML
            return .webm
        }
        if bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 { // OggS
            return .ogg
        }
        return .other
    }

    /// Length of a leading ID3v2 tag (0 when there is none). The size field is
    /// synchsafe: 4 bytes of 7 bits each.
    private static func existingID3Length(handle: FileHandle) throws -> Int {
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: 10), header.count == 10 else { return 0 }
        guard header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 else { return 0 } // "ID3"
        let size = (Int(header[6]) << 21) | (Int(header[7]) << 14) | (Int(header[8]) << 7) | Int(header[9])
        return 10 + size
    }

    // MARK: ID3v2.3

    /// Builds a complete ID3v2.3 tag. Exposed for tests.
    static func buildID3v2Tag(
        title: String,
        artist: String,
        album: String?,
        trackNumber: Int?,
        artworkData: Data?,
        lyricsText: String?,
        year: String?
    ) -> Data {
        var frames = Data()
        if !title.isEmpty { frames.append(textFrame(id: "TIT2", text: title)) }
        if !artist.isEmpty {
            frames.append(textFrame(id: "TPE1", text: artist))
            frames.append(textFrame(id: "TPE2", text: artist))
        }
        if let album, !album.isEmpty { frames.append(textFrame(id: "TALB", text: album)) }
        if let trackNumber { frames.append(textFrame(id: "TRCK", text: String(trackNumber))) }
        if let year, !year.isEmpty { frames.append(textFrame(id: "TYER", text: year)) }
        if let lyricsText, !lyricsText.isEmpty { frames.append(lyricsFrame(lyrics: lyricsText)) }
        if let artworkData, !artworkData.isEmpty { frames.append(pictureFrame(imageData: artworkData)) }

        var tag = Data()
        tag.append(contentsOf: [0x49, 0x44, 0x33]) // "ID3"
        tag.append(contentsOf: [0x03, 0x00]) // version 2.3.0
        tag.append(0x00) // flags
        let size = frames.count
        tag.append(contentsOf: [
            UInt8((size >> 21) & 0x7F),
            UInt8((size >> 14) & 0x7F),
            UInt8((size >> 7) & 0x7F),
            UInt8(size & 0x7F),
        ])
        tag.append(frames)
        return tag
    }

    private static func utf16LEWithBOM(_ text: String) -> Data {
        var data = Data([0xFF, 0xFE])
        for unit in text.utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8((unit >> 8) & 0xFF))
        }
        return data
    }

    private static func frameHeader(id: String, payloadLength: Int) -> Data {
        var header = Data(id.utf8)
        header.append(contentsOf: [
            UInt8((payloadLength >> 24) & 0xFF),
            UInt8((payloadLength >> 16) & 0xFF),
            UInt8((payloadLength >> 8) & 0xFF),
            UInt8(payloadLength & 0xFF),
            0x00, 0x00, // flags
        ])
        return header
    }

    private static func textFrame(id: String, text: String) -> Data {
        let textBytes = utf16LEWithBOM(text)
        var frame = frameHeader(id: id, payloadLength: 1 + textBytes.count)
        frame.append(0x01) // encoding: UTF-16 with BOM
        frame.append(textBytes)
        return frame
    }

    private static func lyricsFrame(lyrics: String) -> Data {
        let lyricBytes = utf16LEWithBOM(lyrics)
        // Body: encoding(1) + language(3) + empty UTF-16 descriptor (2) + text.
        var frame = frameHeader(id: "USLT", payloadLength: 1 + 3 + 2 + lyricBytes.count)
        frame.append(0x01)
        frame.append(contentsOf: [0x65, 0x6E, 0x67]) // "eng"
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(lyricBytes)
        return frame
    }

    private static func pictureFrame(imageData: Data) -> Data {
        let isPNG = imageData.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let mime = isPNG ? "image/png" : "image/jpeg"
        let mimeBytes = Data(mime.utf8)
        var frame = frameHeader(
            id: "APIC",
            payloadLength: 1 + mimeBytes.count + 1 + 1 + 1 + imageData.count
        )
        frame.append(0x00) // encoding: ISO-8859-1 for MIME/description
        frame.append(mimeBytes)
        frame.append(0x00) // MIME null terminator
        frame.append(0x03) // picture type: front cover
        frame.append(0x00) // empty description + null terminator
        frame.append(imageData)
        return frame
    }

    private static func embedID3Prepend(
        fileURL: URL,
        title: String,
        artist: String,
        album: String?,
        artworkData: Data?,
        lyricsText: String?,
        year: String?,
        trackNumber: Int?
    ) throws {
        let tag = buildID3v2Tag(
            title: title, artist: artist, album: album, trackNumber: trackNumber,
            artworkData: artworkData, lyricsText: lyricsText, year: year
        )
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let payloadOffset = (try? existingID3Length(handle: handle)) ?? 0
        let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64 ?? 0

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".tmp")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        do {
            let out = try FileHandle(forWritingTo: tempURL)
            defer { try? out.close() }
            try out.write(contentsOf: tag)
            try handle.seek(toOffset: UInt64(payloadOffset))
            try copyRemaining(from: handle, to: out, bytes: fileSize - UInt64(payloadOffset))
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw AudioTagError.ioError(error.localizedDescription)
        }
        guard try replaceOriginal(fileURL: fileURL, tempURL: tempURL, minimumValidLength: tag.count + 1) else {
            throw AudioTagError.ioError("Tagged file failed validation")
        }
    }

    // MARK: FLAC (native Vorbis comments + PICTURE block)

    private struct FlacBlock {
        var type: Int
        var bodyStart: UInt64
        var bodyLength: Int
    }

    private static func embedIntoFLAC(
        fileURL: URL,
        title: String,
        artist: String,
        album: String?,
        artworkData: Data?,
        lyricsText: String?,
        year: String?
    ) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64 ?? 0
        let flacStart = (try? existingID3Length(handle: handle)) ?? 0

        // Phase 1 — parse the metadata chain (no output written yet).
        try handle.seek(toOffset: UInt64(flacStart))
        guard let magic = try handle.read(upToCount: 4), magic.count == 4,
              String(bytes: magic, encoding: .ascii) == "fLaC"
        else { throw AudioTagError.unsupportedContainer }

        var blocks: [FlacBlock] = []
        var framesStart: UInt64 = 0
        var offset = UInt64(flacStart) + 4
        while true {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 4), header.count == 4 else {
                throw AudioTagError.unsupportedContainer
            }
            let headerByte = Int(header[0])
            let isLast = (headerByte & 0x80) != 0
            let type = headerByte & 0x7F
            let bodyLength = (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            let bodyStart = offset + 4
            guard bodyStart + UInt64(bodyLength) <= fileSize else {
                throw AudioTagError.unsupportedContainer
            }
            blocks.append(FlacBlock(type: type, bodyStart: bodyStart, bodyLength: bodyLength))
            offset = bodyStart + UInt64(bodyLength)
            if isLast { framesStart = offset; break }
        }

        guard let streamInfo = blocks.first(where: { $0.type == 0 }) else {
            throw AudioTagError.unsupportedContainer
        }
        var originalComments: [String] = []
        if let commentBlock = blocks.first(where: { $0.type == 4 }) {
            try handle.seek(toOffset: commentBlock.bodyStart)
            if let body = try handle.read(upToCount: commentBlock.bodyLength) {
                originalComments = parseVorbisComments(Array(body), startOffset: 0)
            }
        }
        let keptBlocks = blocks.filter {
            $0.type != 0 && $0.type != 4 && !($0.type == 6 && artworkData != nil)
        }

        var replacedFields: Set<String> = []
        if !title.isEmpty { replacedFields.insert("TITLE") }
        if !artist.isEmpty { replacedFields.formUnion(["ARTIST", "ALBUMARTIST"]) }
        if let album, !album.isEmpty { replacedFields.insert("ALBUM") }
        if let lyricsText, !lyricsText.isEmpty { replacedFields.formUnion(["LYRICS", "UNSYNCEDLYRICS"]) }
        if let year, !year.isEmpty { replacedFields.formUnion(["DATE", "YEAR"]) }
        if artworkData != nil {
            replacedFields.formUnion(["METADATA_BLOCK_PICTURE", "COVERART", "COVERARTMIME"]) }
        }

        var comments = originalComments.filter {
            !replacedFields.contains($0.split(separator: "=", maxSplits: 1).first.map {
                $0.trimmingCharacters(in: .whitespaces).uppercased()
            } ?? "")
        }
        if !title.isEmpty { comments.append("TITLE=\(title)") }
        if !artist.isEmpty {
            comments.append("ARTIST=\(artist)")
            comments.append("ALBUMARTIST=\(artist)")
        }
        if let album, !album.isEmpty { comments.append("ALBUM=\(album)") }
        if let lyricsText, !lyricsText.isEmpty { comments.append("LYRICS=\(lyricsText)") }
        if let year, !year.isEmpty {
            comments.append("DATE=\(year)")
            comments.append("YEAR=\(year)")
        }

        // Phase 2 — stream the tagged copy to a temp file.
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".flac")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        do {
            let out = try FileHandle(forWritingTo: tempURL)
            defer { try? out.close() }
            try out.write(contentsOf: Data("fLaC".utf8))

            struct OutBlock { var type: Int; var source: FlacBlock?; var generated: Data? }
            var chain: [OutBlock] = [
                OutBlock(type: 0, source: streamInfo, generated: nil),
                OutBlock(type: 4, source: nil, generated: buildVorbisCommentBody(comments)),
            ]
            if let artworkData, !artworkData.isEmpty {
                chain.append(OutBlock(type: 6, source: nil, generated: buildFLACPictureBody(artworkData)))
            }
            for kept in keptBlocks {
                chain.append(OutBlock(type: kept.type, source: kept, generated: nil))
            }

            for (index, block) in chain.enumerated() {
                let isFinal = index == chain.count - 1
                let length = block.source?.bodyLength ?? block.generated?.count ?? 0
                try out.write(contentsOf: Data([
                    UInt8((isFinal ? 0x80 : 0x00) | block.type),
                    UInt8((length >> 16) & 0xFF),
                    UInt8((length >> 8) & 0xFF),
                    UInt8(length & 0xFF),
                ]))
                if let source = block.source {
                    try handle.seek(toOffset: source.bodyStart)
                    try copyRemaining(from: handle, to: out, bytes: UInt64(source.bodyLength))
                } else if let generated = block.generated {
                    try out.write(contentsOf: generated)
                }
            }

            // Audio frames tail — byte-offset free, copied verbatim.
            try handle.seek(toOffset: framesStart)
            try copyRemaining(from: handle, to: out, bytes: fileSize - framesStart)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw AudioTagError.ioError(error.localizedDescription)
        }

        let tempSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? UInt64) ?? 0
        let valid = tempSize > 8
        guard valid, try replaceOriginal(fileURL: fileURL, tempURL: tempURL, minimumValidLength: 9) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw AudioTagError.ioError("Tagged FLAC failed validation")
        }
    }

    /// Little-endian Vorbis comment block body (the FLAC variant has no framing bit).
    private static func buildVorbisCommentBody(_ comments: [String]) -> Data {
        var out = Data()
        let vendor = Data("Wave".utf8)
        out.appendLE32(UInt32(vendor.count))
        out.append(vendor)
        out.appendLE32(UInt32(comments.count))
        for comment in comments {
            let bytes = Data(comment.utf8)
            out.appendLE32(UInt32(bytes.count))
            out.append(bytes)
        }
        return out
    }

    /// Big-endian METADATA_BLOCK_PICTURE body.
    private static func buildFLACPictureBody(_ imageData: Data) -> Data {
        let isPNG = imageData.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let mime = isPNG ? "image/png" : "image/jpeg"
        let (width, height, depth) = imageDimensions(imageData)
        var out = Data()
        out.appendBE32(3) // front cover
        out.appendBE32(UInt32(mime.utf8.count))
        out.append(Data(mime.utf8))
        out.appendBE32(0) // empty description
        out.appendBE32(UInt32(max(0, width)))
        out.appendBE32(UInt32(max(0, height)))
        out.appendBE32(UInt32(depth))
        out.appendBE32(0) // colors
        out.appendBE32(UInt32(imageData.count))
        out.append(imageData)
        return out
    }

    private static func parseVorbisComments(_ bytes: [UInt8], startOffset: Int) -> [String] {
        var offset = startOffset
        guard offset + 4 <= bytes.count else { return [] }
        let vendorLength = readLE32(bytes, offset: offset)
        guard vendorLength >= 0, offset + 4 + vendorLength <= bytes.count else { return [] }
        offset += 4 + vendorLength
        guard offset + 4 <= bytes.count else { return [] }
        let count = readLE32(bytes, offset: offset)
        offset += 4
        guard count >= 0, count <= 10_000 else { return [] }
        var comments: [String] = []
        for _ in 0..<count {
            guard offset + 4 <= bytes.count else { break }
            let length = readLE32(bytes, offset: offset)
            offset += 4
            guard length >= 0, offset + length <= bytes.count else { break }
            comments.append(String(bytes: bytes[offset..<(offset + length)], encoding: .utf8) ?? "")
            offset += length
        }
        return comments
    }

    private static func readLE32(_ bytes: [UInt8], offset: Int) -> Int {
        (Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            | (Int(bytes[offset + 2]) << 16) | (Int(bytes[offset + 3]) << 24))
    }

    /// Image dimensions for the FLAC PICTURE block: PNG header, or a JPEG
    /// start-of-frame scan. Returns (0, 0, 0) when it cannot be determined.
    private static func imageDimensions(_ bytes: Data) -> (Int, Int, Int) {
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]), bytes.count >= 24 {
            let width = Int(bytes[16]) << 24 | Int(bytes[17]) << 16 | Int(bytes[18]) << 8 | Int(bytes[19])
            let height = Int(bytes[20]) << 24 | Int(bytes[21]) << 16 | Int(bytes[22]) << 8 | Int(bytes[23])
            return (max(0, width), max(0, height), 32)
        }
        if bytes.count >= 10, bytes[0] == 0xFF, bytes[1] == 0xD8 {
            let sofMarkers: Set<Int> = [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
            var offset = 2
            let raw = [UInt8](bytes)
            while offset + 9 < raw.count {
                guard raw[offset] == 0xFF else { offset += 1; continue }
                var markerOffset = offset + 1
                while markerOffset < raw.count, raw[markerOffset] == 0xFF { markerOffset += 1 }
                guard markerOffset < raw.count else { break }
                let marker = Int(raw[markerOffset])
                if marker == 0xD8 || marker == 0xD9 || marker == 0x01 {
                    offset = markerOffset + 1
                    continue
                }
                guard markerOffset + 2 < raw.count else { break }
                let segmentLength = (Int(raw[markerOffset + 1]) << 8) | Int(raw[markerOffset + 2])
                guard segmentLength >= 2, markerOffset + 1 + segmentLength <= raw.count else { break }
                if sofMarkers.contains(marker), segmentLength >= 8 {
                    let precision = Int(raw[markerOffset + 3])
                    let height = (Int(raw[markerOffset + 4]) << 8) | Int(raw[markerOffset + 5])
                    let width = (Int(raw[markerOffset + 6]) << 8) | Int(raw[markerOffset + 7])
                    let components = Int(raw[safe: markerOffset + 8] ?? 3)
                    return (width, height, max(1, precision * components))
                }
                offset = markerOffset + 1 + segmentLength
            }
        }
        return (0, 0, 0)
    }

    // MARK: M4A (AVFoundation passthrough export)

    private static func embedIntoM4A(
        fileURL: URL,
        title: String,
        artist: String,
        album: String?,
        artworkData: Data?,
        lyricsText: String?
    ) throws {
        // AVAssetExportSession is callback-based; bridge it synchronously.
        // The download runs on a background task, never the main thread.
        let semaphore = DispatchSemaphore(value: 0)
        var exportError: Error?
        let asset = AVURLAsset(url: fileURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioTagError.exportFailed("Passthrough export session unavailable")
        }
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".m4a")
        session.outputURL = tempURL
        session.outputFileType = .m4a

        var items: [AVMutableMetadataItem] = []
        func textItem(key: AVMetadataKey, value: String) {
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = key as NSCopying & NSObjectProtocol
            item.value = value as NSString
            items.append(item)
        }
        if !title.isEmpty { textItem(key: .commonKeyTitle, value: title) }
        if !artist.isEmpty { textItem(key: .commonKeyArtist, value: artist) }
        if let album, !album.isEmpty { textItem(key: .commonKeyAlbumName, value: album) }
        if let lyricsText, !lyricsText.isEmpty {
            let item = AVMutableMetadataItem()
            item.keySpace = .iTunes
            item.key = "©lyr" as NSCopying & NSObjectProtocol
            item.value = lyricsText as NSString
            items.append(item)
        }
        if let artworkData, !artworkData.isEmpty {
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = AVMetadataKey.commonKeyArtwork as NSCopying & NSObjectProtocol
            item.value = artworkData as NSData
            let isPNG = artworkData.starts(with: [0x89, 0x50, 0x4E, 0x47])
            item.dataType = isPNG ? "com.apple.metadata.datatype.PNG" : "com.apple.metadata.datatype.JPEG"
            items.append(item)
        }
        session.metadata = items

        session.exportAsynchronously {
            if session.status == .failed {
                exportError = session.error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let exportError {
            try? FileManager.default.removeItem(at: tempURL)
            throw AudioTagError.exportFailed(exportError.localizedDescription)
        }
        guard try replaceOriginal(fileURL: fileURL, tempURL: tempURL, minimumValidLength: 16) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw AudioTagError.ioError("Tagged M4A failed validation")
        }
    }

    // MARK: File helpers

    private static func copyRemaining(from handle: FileHandle, to out: FileHandle, bytes: UInt64) throws {
        var remaining = bytes
        while remaining > 0 {
            let chunk = Int(min(remaining, 64 * 1024))
            guard let data = try handle.read(upToCount: chunk), !data.isEmpty else { break }
            try out.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
    }

    /// Atomically replaces the original with the validated temp file.
    /// Returns false when the temp file is missing or too small.
    private static func replaceOriginal(fileURL: URL, tempURL: URL, minimumValidLength: Int) throws -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? UInt64,
              size >= UInt64(minimumValidLength)
        else { return false }
        do {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            return true
        } catch {
            // Fallback for filesystems where replaceItemAt fails.
            try? FileManager.default.removeItem(at: fileURL)
            do {
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
                return true
            } catch {
                return false
            }
        }
    }
}

// MARK: - Data byte helpers

private extension Data {
    mutating func appendLE32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    mutating func appendBE32(_ value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }
}

private extension Array where Element == UInt8 {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
