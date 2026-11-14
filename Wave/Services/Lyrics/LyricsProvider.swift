import Foundation

// MARK: - Download manager
//
// Background `URLSession` downloads of YouTube Music audio streams. Files
// land in the app container under `Downloads/`, named
// `<artist> - <title>.<ext>` (sanitised, matching the Android app). After
// the download, tags are written (see `AudioTagWriter`) and a `.lrc` sidecar
// is written when synced lyrics exist.
//
// Format choice: audio/mp4 (m4a/AAC) is preferred when available — it plays
// everywhere on iOS and takes native metadata. WebM/Opus is the fallback;
// Opus-in-WebM keeps its file name and .lrc sidecar but gets no embedded
// tags (no native WebM tag writer on iOS; see `AudioTagWriter`).
//
// Background sessions: the delegate moves the finished file to a staging
// location synchronously inside `didFinishDownloadingTo` (the system deletes
// the temp file as soon as that callback returns), then hands the staged URL
// to the manager on the main actor. A background completion handler for
// wake-ups while suspended needs a UIApplicationDelegate adaptor in the app
// target; downloads started while the app is in the foreground work fully
// without one.

enum DownloadError: Error, LocalizedError {
    case noStreamAvailable
    case network(Error)
    case httpStatus(Int)
    case fileSystem(Error)

    var errorDescription: String? {
        switch self {
        case .noStreamAvailable: return "No playable audio stream is available for this track"
        case .network(let error): return error.localizedDescription
        case .httpStatus(let code): return "Download failed (HTTP \(code))"
        case .fileSystem(let error): return error.localizedDescription
        }
    }
}

/// `URLSessionDownloadDelegate` that lives off the main actor (URLSession
/// calls it on its own delegate queue) and forwards events to the manager.
private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    nonisolated(unsafe) weak var manager: DownloadManager?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move synchronously: the system deletes `location` on return.
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(location.pathExtension)
        do {
            try FileManager.default.moveItem(at: location, to: stagedURL)
        } catch {
            Task { @MainActor [weak manager] in
                manager?.finishDownload(taskIdentifier: downloadTask.taskIdentifier, error: error)
            }
            return
        }
        Task { @MainActor [weak manager] in
            manager?.finishDownload(taskIdentifier: downloadTask.taskIdentifier, stagedURL: stagedURL)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak manager] in
            manager?.updateProgress(taskIdentifier: downloadTask.taskIdentifier, fraction: fraction)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor [weak manager] in
            manager?.finishDownload(taskIdentifier: task.taskIdentifier, error: error)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // The app has no UIApplicationDelegate adaptor; nothing to resume here.
        // Downloads started in the foreground are delivered through the
        // callbacks above.
    }
}

@MainActor
@Observable
final class DownloadManager {
    static let backgroundIdentifier = "app.wave.downloads"

    private let innerTube: InnerTubeService
    private let lyrics: LyricsService
    private let settings: SettingsStore
    private let session: URLSession
    private let delegate = DownloadSessionDelegate()
    private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]
    private var taskTracks: [Int: String] = [:]

    /// Download progress by track id (0.0–1.0). Observed by the UI.
    var progress: [String: Double] = [:]

    init(
        innerTube: InnerTubeService,
        lyrics: LyricsService,
        settings: SettingsStore = .shared
    ) {
        self.innerTube = innerTube
        self.lyrics = lyrics
        self.settings = settings
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        configuration.sessionSendsLaunchEvents = true
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.manager = self
    }

    /// Resolves the stream URL via InnerTube, then downloads, tags and
    /// returns the final file URL.
    func download(_ track: Track) async throws -> URL {
        let stream = try await innerTube.player(videoId: track.id)
        guard let format = bestFormat(in: stream.formats) else {
            throw DownloadError.noStreamAvailable
        }
        return try await download(track: track, streamURL: format.url, mimeType: format.mimeType)
    }

    /// Downloads a known stream URL, writes tags and the `.lrc` sidecar,
    /// and returns the final file URL in `Downloads/`.
    func download(track: Track, streamURL: URL, mimeType: String? = nil) async throws -> URL {
        let fileExtension = Self.fileExtension(for: mimeType ?? streamURL.pathExtension)
        let baseName = AudioTagWriter.sanitizeFileName("\(track.artistNames) - \(track.title)")
        let destination = downloadsFolder
            .appendingPathComponent(baseName)
            .appendingPathExtension(fileExtension)

        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        var request = URLRequest(url: streamURL)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let stagedURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let task = session.downloadTask(with: request)
            continuations[task.taskIdentifier] = continuation
            taskTracks[task.taskIdentifier] = track.id
            progress[track.id] = 0
            task.resume()
        }

        do {
            try FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: stagedURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw DownloadError.fileSystem(error)
        }

        // Tags and lyrics sidecar are best-effort: a tagging failure must
        // not lose the download. The M4A writer blocks on an export
        // semaphore, so it runs off the main actor in a detached task.
        let lyricsResult = await lyrics.lyrics(for: track)
        let artworkData = await fetchArtworkData(for: track)
        do {
            try await Task.detached {
                try AudioTagWriter.writeTags(
                    track: track,
                    to: destination,
                    artworkData: artworkData,
                    lyricsText: lyricsResult?.plainText,
                    trackNumber: nil
                )
            }.value
        } catch {
            // Leave the file untagged (e.g. WebM/Opus has no native writer).
        }
        if let lyricsResult {
            try? AudioTagWriter.writeLyricsSidecar(track: track, lyrics: lyricsResult, to: downloadsFolder)
        }
        progress[track.id] = nil
        return destination
    }

    /// Cancels an in-flight download for the track, if any.
    func cancelDownload(for track: Track) {
        Task {
            for task in await session.allTasks where task is URLSessionDownloadTask {
                if taskTracks[task.taskIdentifier] == track.id {
                    task.cancel()
                    progress[track.id] = nil
                }
            }
        }
    }

    /// The folder downloaded files live in (app container, `Downloads/`).
    var downloadsFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("Downloads", isDirectory: true)
    }

    // MARK: - Delegate callbacks (called on the main actor)

    func updateProgress(taskIdentifier: Int, fraction: Double) {
        guard let trackId = taskTracks[taskIdentifier] else { return }
        progress[trackId] = fraction
    }

    func finishDownload(taskIdentifier: Int, stagedURL: URL) {
        guard let continuation = continuations.removeValue(forKey: taskIdentifier) else {
            // A task from a previous launch; nothing is waiting for it.
            try? FileManager.default.removeItem(at: stagedURL)
            taskTracks.removeValue(forKey: taskIdentifier)
            return
        }
        taskTracks.removeValue(forKey: taskIdentifier)
        continuation.resume(returning: stagedURL)
    }

    func finishDownload(taskIdentifier: Int, error: Error) {
        guard let continuation = continuations.removeValue(forKey: taskIdentifier) else { return }
        if let trackId = taskTracks.removeValue(forKey: taskIdentifier) {
            progress[trackId] = nil
        }
        continuation.resume(throwing: DownloadError.network(error))
    }

    // MARK: - Helpers

    /// Picks the download format: audio/mp4 first (iOS-native, taggable),
    /// then the closest bitrate to the download quality setting.
    func bestFormat(in formats: [AudioFormat]) -> AudioFormat? {
        let audio = formats.filter { $0.mimeType.lowercased().contains("audio") }
        guard !audio.isEmpty else { return nil }
        let target = settings.downloadQuality.targetBitrateKbps * 1_000
        return audio.sorted { lhs, rhs in
            let lhsMP4 = lhs.mimeType.lowercased().contains("audio/mp4")
            let rhsMP4 = rhs.mimeType.lowercased().contains("audio/mp4")
            if lhsMP4 != rhsMP4 { return lhsMP4 }
            return abs(lhs.bitrate - target) < abs(rhs.bitrate - target)
        }.first
    }

    static func fileExtension(for mimeTypeOrExtension: String) -> String {
        let value = mimeTypeOrExtension.lowercased()
        if value.contains("audio/mp4") || value == "m4a" { return "m4a" }
        if value.contains("audio/webm") || value == "webm" { return "webm" }
        if value.contains("audio/mpeg") || value == "mp3" { return "mp3" }
        if value.contains("audio/flac") || value == "flac" { return "flac" }
        if value.contains("audio/ogg") || value.contains("opus") || value == "opus" { return "opus" }
        let cleaned = value.split(separator: "/").last.map(String.init) ?? value
        return cleaned.isEmpty ? "m4a" : cleaned
    }

    private func fetchArtworkData(for track: Track) async -> Data? {
        guard let url = track.artworkURL else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data.count <= AudioTagWriter.maxArtworkBytes ? data : Data(data.prefix(AudioTagWriter.maxArtworkBytes))
        } catch {
            return nil
        }
    }

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}



