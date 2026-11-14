import AVFoundation
import Foundation
import MediaPlayer
import Network
import Observation
import UIKit

// MARK: - Player
//
// The single playback engine for the app. Two paths, chosen per track:
//
//  * Streamed YouTube Music audio -> `AVPlayer`. This is the default: it
//    handles network buffering, background audio and the lock screen, and it
//    supports tempo via `audioTimePitchAlgorithm`.
//  * Local/downloaded files, and any track that needs the EQ, a pitch shift
//    or Automix -> `AutomixEngine` (an `AVAudioEngine` with two player
//    decks, a time-pitch unit and a 15-band EQ). A streamed track that needs
//    this path is first downloaded to a temp file — the stream itself is
//    only a few MB of audio, so the delay is short. If that download fails,
//    the player falls back to the `AVPlayer` path so the music keeps
//    playing, just without EQ/pitch for that track.
//
// Only MP4/AAC stream formats are playable: AVFoundation cannot play
// Opus/WebM, so `bestFormat(from:)` filters to `audio/mp4` first.
//
// The UI never touches AVFoundation directly — everything goes through
// `PlaybackEngine` (see `PlaybackEngine.swift`).

enum PlayerError: LocalizedError {
    case noPlayableFormat
    case noTrackLoaded

    var errorDescription: String? {
        switch self {
        case .noPlayableFormat:
            "No playable audio format was found for this track. iOS can only play the MP4/AAC stream; the Opus/WebM variants are not supported."
        case .noTrackLoaded:
            "No track is loaded."
        }
    }
}

@MainActor
@Observable
final class Player: PlaybackEngine {
    static let shared = Player(innerTube: InnerTubeClient.shared, lyrics: LyricsProvider.shared)

    // MARK: - Protocol state

    private(set) var state: PlayerState = .idle
    private(set) var currentTrack: Track?
    private(set) var queue: [QueueItem] = []
    private(set) var queueIndex: Int = 0
    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    var isShuffleEnabled: Bool = false
    var repeatMode: RepeatMode = .off

    // MARK: - Public extras (not in the protocol)

    /// 0.5–2.0, 1.0 = normal tempo. Applies live on both paths. A computed
    /// property over a private backing store (instead of a `didSet` that
    /// clamps by reassigning) so the clamp can never recurse.
    private var _playbackRate: Double = 1.0
    var playbackRate: Double {
        get { _playbackRate }
        set {
            let clamped = min(max(newValue, 0.5), 2.0)
            guard clamped != _playbackRate else { return }
            _playbackRate = clamped
            if useEnginePath {
                automix.setRate(clamped, pitchSemitones: pitchSemitones)
            } else {
                player.defaultRate = Float(clamped)
                if state == .playing {
                    player.rate = Float(clamped)
                }
            }
            updateNowPlayingInfo()
        }
    }

    /// Pitch shift in semitones, 0 = unchanged. Only the engine path can
    /// shift pitch (`AVPlayer` can only preserve it), so setting this while
    /// a stream plays on the `AVPlayer` path reloads the current track
    /// through the engine (position preserved).
    var pitchSemitones: Double = 0 {
        didSet {
            guard oldValue != pitchSemitones else { return }
            if pitchSemitones != 0, !useEnginePath, currentTrack != nil {
                reloadCurrentPreservingPosition()
            } else {
                automix.setRate(playbackRate, pitchSemitones: pitchSemitones)
            }
        }
    }

    /// Master EQ switch. Turning it on while a stream plays on the
    /// `AVPlayer` path reloads the current track through the engine
    /// (position preserved); turning it off just flattens the EQ live.
    var eqEnabled: Bool = false {
        didSet {
            guard oldValue != eqEnabled else { return }
            if eqEnabled, !useEnginePath, currentTrack != nil {
                reloadCurrentPreservingPosition()
            } else {
                automix.applyEQ(eqSettings, enabled: eqEnabled)
            }
        }
    }

    /// The 15-band EQ. Applied live to the engine when it is the active
    /// path. Kept in sync with the AutoEQ settings by
    /// `refreshEQFromSettings()` (see below).
    var eqSettings: EQSettings = .flat {
        didSet {
            automix.applyEQ(eqSettings, enabled: eqEnabled)
        }
    }

    var currentLyrics: Lyrics?
    var lyricsLoading: Bool = false

    /// Google Cast is not in this build (it needs the Cast iOS SDK via
    /// CocoaPods). The player UI shows an explainer sheet instead of a
    /// device list. See `docs/ARCHITECTURE.md`.
    var castAvailable: Bool { false }

    // MARK: - Dependencies and engines

    private let innerTube: InnerTubeService
    private let lyrics: LyricsService
    private let player = AVPlayer()
    private let automix = AutomixEngine()
    private let networkMonitor = NWPathMonitor()

    // `deinit` is nonisolated and must cancel timers/tasks and remove
    // observers, so these are `nonisolated(unsafe)`. That is sound here:
    // `invalidate()`, `cancel()` and `removeObserver(_:)` are all safe to
    // call from any thread, and every other access happens on the main actor.
    private nonisolated(unsafe) var positionTimer: Timer?
    private nonisolated(unsafe) var sleepTimer: Timer?
    private nonisolated(unsafe) var loadTask: Task<Void, Never>?
    private nonisolated(unsafe) var lyricsTask: Task<Void, Never>?
    private nonisolated(unsafe) var failureSkipTask: Task<Void, Never>?
    private nonisolated(unsafe) var crossfadeTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var networkIsCellular = false
    private var useEnginePath = false
    private var isCrossfading = false
    private var hasScrobbled = false
    private var resumePosition: Double?
    private var wasPlayingBeforeInterruption = false
    private var lastSnapshotWrite = Date.distantPast
    private var currentTempFile: URL?
    private var forcedURLForNextLoad: URL?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []

    init(innerTube: InnerTubeService, lyrics: LyricsService) {
        self.innerTube = innerTube
        self.lyrics = lyrics

        automix.audioURLProvider = { [weak self] track in
            guard let self else { throw PlayerError.noTrackLoaded }
            return try await self.resolveAudioURL(for: track)
        }
        automix.onTrackFinished = { [weak self] in
            Task { @MainActor [weak self] in
                self?.trackDidFinish()
            }
        }

        configureAudioSession()
        setupRemoteCommands()
        setupNotifications()
        setupNetworkMonitor()
        startPositionTimer()
        observeSettings()
        refreshEQFromSettings()
    }

    deinit {
        positionTimer?.invalidate()
        sleepTimer?.invalidate()
        loadTask?.cancel()
        lyricsTask?.cancel()
        failureSkipTask?.cancel()
        crossfadeTask?.cancel()
        networkMonitor.cancel()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - PlaybackEngine

    func play(_ track: Track) {
        queue = [QueueItem(track: track)]
        queueIndex = 0
        loadCurrent()
    }

    func playAll(_ tracks: [Track], startingAt index: Int) {
        guard !tracks.isEmpty else { return }
        queue = tracks.map(QueueItem.init)
        queueIndex = min(max(index, 0), tracks.count - 1)
        loadCurrent()
    }

    /// Plays a downloaded track from its exact local file, without the
    /// filename heuristic `loadCurrent` would otherwise use.
    func playDownloaded(_ downloaded: DownloadedTrack) {
        queue = [QueueItem(track: downloaded.track)]
        queueIndex = 0
        forcedURLForNextLoad = downloaded.localURL
        loadCurrent()
    }

    func togglePlayPause() {
        switch state {
        case .playing:
            pausePlayback()
        case .paused:
            resumePlayback()
        case .stopped, .idle:
            if currentTrack != nil {
                loadCurrent()
            }
        case .failed:
            if currentTrack != nil {
                loadCurrent()
            }
        case .loading:
            break
        }
    }

    func next() {
        guard let (track, index) = nextTrackWithIndex() else {
            stopAtEnd()
            return
        }
        if SettingsStore.shared.automixEnabled, useEnginePath, state == .playing, !isCrossfading {
            triggerCrossfade(to: track, index: index, hardFallback: true)
        } else {
            queueIndex = index
            loadCurrent()
        }
    }

    func previous() {
        if positionSeconds > 3 {
            seek(to: 0)
            return
        }
        guard queueIndex > 0 else {
            seek(to: 0)
            return
        }
        queueIndex -= 1
        loadCurrent()
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), durationSeconds > 0 ? durationSeconds : seconds)
        if useEnginePath {
            automix.seek(to: clamped)
        } else {
            player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        }
        positionSeconds = clamped
        updateNowPlayingInfo()
    }

    func addToQueue(_ track: Track) {
        let wasEmpty = queue.isEmpty
        queue.append(QueueItem(track: track))
        if wasEmpty, currentTrack == nil {
            queueIndex = 0
            loadCurrent()
        }
    }

    func removeFromQueue(at offsets: IndexSet) {
        guard !offsets.isEmpty, !queue.isEmpty else { return }
        let removedCurrent = offsets.contains(queueIndex)
        let removedBeforeCurrent = offsets.filter { $0 < queueIndex }.count
        queue.remove(atOffsets: offsets)
        if queue.isEmpty {
            stopEverything()
            return
        }
        if removedCurrent {
            queueIndex = min(queueIndex, queue.count - 1)
            loadCurrent()
        } else {
            queueIndex -= removedBeforeCurrent
        }
    }

    func moveQueue(from source: IndexSet, to destination: Int) {
        let currentId = queue.indices.contains(queueIndex) ? queue[queueIndex].id : nil
        queue.move(fromOffsets: source, toOffset: destination)
        if let currentId, let newIndex = queue.firstIndex(where: { $0.id == currentId }) {
            queueIndex = newIndex
        }
    }

    func startRadio(for track: Track) async {
        do {
            let results = try await innerTube.next(videoId: track.id, playlistId: nil)
            playAll([track] + results, startingAt: 0)
        } catch {
            // Radio failed; the track itself still plays.
            play(track)
        }
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        guard minutes > 0 else { return }
        SettingsStore.shared.sleepTimerMinutes = minutes
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sleepTimerDidFire()
            }
        }
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        SettingsStore.shared.sleepTimerMinutes = 0
    }

    private func sleepTimerDidFire() {
        sleepTimer = nil
        SettingsStore.shared.sleepTimerMinutes = 0
        if state == .playing {
            pausePlayback()
        }
    }

    // MARK: - Track loading

    private func loadCurrent() {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        lyricsTask?.cancel()
        failureSkipTask?.cancel()
        crossfadeTask?.cancel()
        crossfadeTask = nil
        isCrossfading = false
        hasScrobbled = false

        guard queue.indices.contains(queueIndex) else {
            stopEverything()
            return
        }
        let track = queue[queueIndex].track
        currentTrack = track
        LibraryStoreImpl.shared.recordPlayed(track)
        state = .loading
        positionSeconds = 0
        durationSeconds = Double(track.durationSeconds ?? 0)
        nowPlayingArtwork = nil

        loadLyrics(for: track)
        writeWidgetSnapshot()
        updateNowPlayingInfo()
        fetchArtwork(for: track)

        loadTask = Task {
            await self.loadAudio(for: track, generation: generation)
        }
    }

    private func loadAudio(for track: Track, generation: Int) async {
        // The engine path is needed for local files, EQ, pitch shift and
        // Automix. Everything else streams through AVPlayer.
        let needsEngine = localFileURL(for: track) != nil
            || forcedURLForNextLoad != nil
            || eqEnabled
            || pitchSemitones != 0
            || SettingsStore.shared.automixEnabled
        if needsEngine {
            await loadViaEngine(for: track, generation: generation)
        } else {
            await loadViaPlayer(for: track, generation: generation)
        }
    }

    private func loadViaPlayer(for track: Track, generation: Int) async {
        do {
            let url = try await resolveStreamURL(for: track)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .spectral
            useEnginePath = false
            automix.stop()
            player.replaceCurrentItem(with: item)
            player.defaultRate = Float(playbackRate)
            applyLoudness(for: track)
            player.play()
            // The position timer flips state to .playing once the item
            // reports readyToPlay.
        } catch {
            guard generation == loadGeneration else { return }
            failCurrentTrack(error)
        }
    }

    private func loadViaEngine(for track: Track, generation: Int) async {
        do {
            let url = try await resolveAudioURL(for: track)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            useEnginePath = true
            player.pause()
            player.replaceCurrentItem(with: nil)
            automix.applyEQ(eqSettings, enabled: eqEnabled)
            automix.setRate(playbackRate, pitchSemitones: pitchSemitones)
            applyLoudness(for: track)
            guard automix.play(url: url, track: track) else {
                // The file cannot be opened (e.g. an Opus/WebM download).
                // Fall through to the streaming fallback below.
                throw PlayerError.noPlayableFormat
            }
            state = .playing
            if let resume = resumePosition {
                resumePosition = nil
                automix.seek(to: resume)
                positionSeconds = resume
            }
            updateNowPlayingInfo()
        } catch {
            guard generation == loadGeneration else { return }
            // The engine path failed (usually the stream download). Fall
            // back to plain AVPlayer streaming so the music keeps playing,
            // just without EQ / pitch / Automix for this track.
            await loadViaPlayerFallback(for: track, generation: generation)
        }
    }

    private func loadViaPlayerFallback(for track: Track, generation: Int) async {
        do {
            let url = try await resolveStreamURL(for: track)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .spectral
            useEnginePath = false
            player.replaceCurrentItem(with: item)
            player.defaultRate = Float(playbackRate)
            applyLoudness(for: track)
            player.play()
        } catch {
            guard generation == loadGeneration else { return }
            failCurrentTrack(error)
        }
    }

    private func reloadCurrentPreservingPosition() {
        guard currentTrack != nil else { return }
        resumePosition = positionSeconds
        loadCurrent()
    }

    // MARK: - Stream and file resolution

    /// Best playable audio format: MP4/AAC only (AVFoundation cannot play
    /// Opus/WebM). Prefers the highest bitrate at or under the effective
    /// target; if every format is above the target, takes the lowest one.
    /// `AudioFormat.bitrate` is in bits per second, as returned by YouTube.
    func bestFormat(from formats: [AudioFormat]) -> AudioFormat? {
        let playable = formats.filter { $0.mimeType.lowercased().hasPrefix("audio/mp4") }
        guard !playable.isEmpty else { return nil }
        let targetKbps = effectiveTargetBitrateKbps()
        let under = playable
            .filter { $0.bitrate / 1000 <= targetKbps }
            .max(by: { $0.bitrate < $1.bitrate })
        if let under { return under }
        return playable.min(by: { $0.bitrate < $1.bitrate })
    }

    /// Effective bitrate target in kbps: the quality setting, capped at
    /// 192 kbps on cellular so a stream does not burn mobile data.
    func effectiveTargetBitrateKbps() -> Int {
        let target = SettingsStore.shared.audioQuality.targetBitrateKbps
        return networkIsCellular ? min(target, 192) : target
    }

    private func resolveStreamURL(for track: Track) async throws -> URL {
        let info = try await innerTube.player(videoId: track.id)
        guard let format = bestFormat(from: info.formats) else {
            throw PlayerError.noPlayableFormat
        }
        return format.url
    }

    /// Resolves a track to a local audio file URL for the engine path:
    /// an explicitly forced URL, a downloaded file, a previously downloaded
    /// stream in the temp directory, or a fresh stream download.
    func resolveAudioURL(for track: Track) async throws -> URL {
        if let forced = forcedURLForNextLoad {
            forcedURLForNextLoad = nil
            return forced
        }
        if let local = localFileURL(for: track) {
            return local
        }
        let tempDir = FileManager.default.temporaryDirectory
        if let cached = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasPrefix("wave-\(track.id).") }) {
            return cached
        }
        let info = try await innerTube.player(videoId: track.id)
        guard let format = bestFormat(from: info.formats) else {
            throw PlayerError.noPlayableFormat
        }
        return try await downloadStreamToTempFile(url: format.url, mimeType: format.mimeType, trackId: track.id)
    }

    private func downloadStreamToTempFile(url: URL, mimeType: String, trackId: String) async throws -> URL {
        let (tempURL, _) = try await URLSession.shared.download(from: url)
        let ext: String
        if mimeType.lowercased().contains("webm") {
            ext = "webm"
        } else if mimeType.lowercased().contains("mp4") {
            ext = "m4a"
        } else {
            ext = "m4a"
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave-\(trackId).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        if let old = currentTempFile, old != destination {
            try? FileManager.default.removeItem(at: old)
        }
        currentTempFile = destination
        return destination
    }

    /// Finds a downloaded file for a track by the app's download naming
    /// (`<artist> - <title>.<ext>` under Documents/Downloads). This is a
    /// heuristic — the exact file is known when the UI calls
    /// `playDownloaded(_:)`, which bypasses it.
    func localFileURL(for track: Track) -> URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Downloads", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let wanted = sanitizedFileName("\(track.artistNames) - \(track.title)")
        for file in files {
            let stem = sanitizedFileName(file.deletingPathExtension().lastPathComponent)
            if stem == wanted || file.lastPathComponent.contains(track.id) {
                return file
            }
        }
        return nil
    }

    private func sanitizedFileName(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var kept = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "-" {
                kept.unicodeScalars.append(scalar)
            }
        }
        return kept.split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Queue advancement

    private func nextTrackWithIndex() -> (track: Track, index: Int)? {
        guard !queue.isEmpty else { return nil }
        if isShuffleEnabled, queue.count > 1 {
            var candidates = Array(queue.indices)
            candidates.removeAll { $0 == queueIndex }
            guard let picked = candidates.randomElement() else { return nil }
            return (queue[picked].track, picked)
        }
        let next = queueIndex + 1
        if next < queue.count {
            return (queue[next].track, next)
        }
        if repeatMode == .all, !queue.isEmpty {
            return (queue[0].track, 0)
        }
        return nil
    }

    private func triggerCrossfade(to next: Track, index: Int, hardFallback: Bool) {
        guard !isCrossfading else { return }
        isCrossfading = true
        crossfadeTask = Task {
            let ok = await self.automix.crossfade(to: next)
            guard !Task.isCancelled else { return }
            if ok {
                self.completeCrossfade(to: index, track: next)
            } else {
                self.isCrossfading = false
                if hardFallback {
                    self.queueIndex = index
                    self.loadCurrent()
                }
            }
        }
    }

    private func completeCrossfade(to index: Int, track: Track) {
        queueIndex = index
        currentTrack = track
        isCrossfading = false
        hasScrobbled = false
        positionSeconds = 0
        durationSeconds = automix.durationSeconds
        loadLyrics(for: track)
        writeWidgetSnapshot()
        updateNowPlayingInfo()
        fetchArtwork(for: track)
    }

    private func trackDidFinish() {
        guard state == .playing || state == .loading else { return }
        if repeatMode == .one {
            seek(to: 0)
            resumePlayback()
            return
        }
        guard let (_, index) = nextTrackWithIndex() else {
            stopAtEnd()
            return
        }
        queueIndex = index
        loadCurrent()
    }

    private func stopAtEnd() {
        player.pause()
        automix.stop()
        state = .stopped
        positionSeconds = 0
        writeWidgetSnapshot()
        updateNowPlayingInfo()
    }

    private func stopEverything() {
        crossfadeTask?.cancel()
        crossfadeTask = nil
        loadTask?.cancel()
        lyricsTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        automix.stop()
        currentTrack = nil
        currentLyrics = nil
        queue = []
        queueIndex = 0
        state = .idle
        positionSeconds = 0
        durationSeconds = 0
        updateNowPlayingInfo()
    }

    private func pausePlayback() {
        crossfadeTask?.cancel()
        crossfadeTask = nil
        isCrossfading = false
        if useEnginePath {
            automix.pause()
        } else {
            player.pause()
        }
        state = .paused
        writeWidgetSnapshot()
        updateNowPlayingInfo()
    }

    private func resumePlayback() {
        if useEnginePath {
            automix.resume()
        } else {
            player.play()
            player.rate = Float(playbackRate)
        }
        state = .playing
        updateNowPlayingInfo()
    }

    private func failCurrentTrack(_ error: Error) {
        player.pause()
        automix.stop()
        state = .failed(error.localizedDescription)
        updateNowPlayingInfo()
        // Skip to the next item after a short delay so one dead stream
        // does not end the session. If there is nothing after this track,
        // the failed state stays put.
        guard nextTrackWithIndex() != nil else { return }
        failureSkipTask?.cancel()
        failureSkipTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            if case .failed = self.state {
                self.next()
            }
        }
    }

    // MARK: - Lyrics

    private func loadLyrics(for track: Track) {
        lyricsTask?.cancel()
        currentLyrics = nil
        lyricsLoading = true
        lyricsTask = Task {
            let result = await self.lyrics.lyrics(for: track)
            guard !Task.isCancelled else { return }
            // Only keep the result if the track has not changed meanwhile.
            guard self.currentTrack?.id == track.id else { return }
            self.currentLyrics = result
            self.lyricsLoading = false
        }
    }

    // MARK: - Loudness

    private func applyLoudness(for track: Track) {
        guard SettingsStore.shared.loudnessNormalizationEnabled else {
            applyVolume(1)
            return
        }
        // No measured loudness exists for any track yet (see Loudness.swift),
        // so this is 0 dB today and a real adjustment once a source exists.
        let gain = gainAdjustment(for: track, measuredLoudness: nil)
        applyVolume(linearGain(fromDb: Double(gain)))
    }

    private func applyVolume(_ volume: Float) {
        player.volume = volume
        automix.setVolume(volume)
    }

    // MARK: - AutoEQ sync

    /// Applies the AutoEQ headphone selected in Settings. Called when the
    /// settings change and once at startup. Only the 20 bundled headphone
    /// profiles are available offline; anything else leaves the manual EQ
    /// untouched.
    func refreshEQFromSettings() {
        let settings = SettingsStore.shared
        guard settings.autoEQEnabled, let name = settings.selectedHeadphone,
              let library = AutoEQLibrary.load(),
              let preset = library.preset(named: name) else { return }
        eqSettings = library.eqSettings(for: preset)
        if !eqEnabled {
            eqEnabled = true
        }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = SettingsStore.shared.autoEQEnabled
            _ = SettingsStore.shared.selectedHeadphone
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshEQFromSettings()
                self?.observeSettings()
            }
        }
    }

    // MARK: - Position timer

    private func startPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard currentTrack != nil else { return }

        if useEnginePath {
            positionSeconds = automix.positionSeconds
            if automix.durationSeconds > 0 {
                durationSeconds = automix.durationSeconds
            }
        } else if let item = player.currentItem {
            let pos = item.currentTime().seconds
            if pos.isFinite {
                positionSeconds = pos
            }
            let dur = item.duration.seconds
            if dur.isFinite, dur > 0 {
                durationSeconds = dur
            }
            if state == .loading {
                switch item.status {
                case .readyToPlay:
                    state = .playing
                    if let resume = resumePosition {
                        resumePosition = nil
                        seek(to: resume)
                    }
                    updateNowPlayingInfo()
                case .failed:
                    failCurrentTrack(item.error ?? PlayerError.noPlayableFormat)
                default:
                    break
                }
            }
        }

        // Last.fm scrobble at the halfway point, once per track.
        if state == .playing, durationSeconds > 0, !hasScrobbled,
           positionSeconds >= durationSeconds / 2,
           let track = currentTrack {
            hasScrobbled = true
            if LastFmService.shared.isConfigured {
                Task {
                    await LastFmService.shared.scrobble(track: track)
                }
            }
        }

        // Automix: start the crossfade when the remaining time drops to
        // the crossfade length. Only on the engine path — the AVPlayer
        // path has no second deck. Repeat-one replays the same track, so
        // there is no next track to crossfade into.
        if useEnginePath, SettingsStore.shared.automixEnabled, state == .playing,
           !isCrossfading, repeatMode != .one {
            let remaining = durationSeconds - positionSeconds
            if remaining <= automix.crossfadeDuration, remaining > 0,
               let (track, index) = nextTrackWithIndex() {
                triggerCrossfade(to: track, index: index, hardFallback: false)
            }
        }

        // Widget snapshot every 15 s while playing.
        if state == .playing, Date().timeIntervalSince(lastSnapshotWrite) >= 15 {
            writeWidgetSnapshot()
        }

        updateNowPlayingElapsed()
    }

    // MARK: - Widget snapshot

    private func writeWidgetSnapshot() {
        guard let track = currentTrack else { return }
        WidgetSnapshotWriter.write(WaveWidgetSnapshot(
            trackTitle: track.title,
            artistName: track.artistNames,
            artworkURL: track.artworkURL,
            isPlaying: state == .playing,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds
        ))
        lastSnapshotWrite = Date()
    }

    // MARK: - Now Playing and remote commands

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistNames,
            MPMediaItemPropertyAlbumTitle: track.album?.title ?? "",
            MPMediaItemPropertyPlaybackDuration: durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? playbackRate : 0,
        ]
        if let artwork = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingElapsed() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
              currentTrack != nil else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = positionSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = state == .playing ? playbackRate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func fetchArtwork(for track: Track) {
        guard let url = track.artworkURL else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            guard self.currentTrack?.id == track.id else { return }
            self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlayingInfo()
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.resumePlayback() }
            return self.currentTrack == nil ? .noSuchContent : .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.pausePlayback() }
            return self.currentTrack == nil ? .noSuchContent : .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.togglePlayPause() }
            return self.currentTrack == nil ? .noSuchContent : .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self.seek(to: event.positionTime) }
            return .success
        }
    }

    // MARK: - Audio session, interruptions, network

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth])
            try session.setActive(true)
        } catch {
            // Playback still works without an active session in most cases;
            // the failure surfaces as missing background audio, not a crash.
        }
    }

    private func setupNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleInterruption(note)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(note)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, !self.useEnginePath,
                      note.object as? AVPlayerItem === self.player.currentItem else { return }
                self.trackDidFinish()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, !self.useEnginePath,
                      note.object as? AVPlayerItem === self.player.currentItem else { return }
                let error = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
                    ?? PlayerError.noPlayableFormat
                self.failCurrentTrack(error)
            }
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let userInfo = note.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            if state == .playing {
                wasPlayingBeforeInterruption = true
                pausePlayback()
            }
        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume), wasPlayingBeforeInterruption {
                resumePlayback()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let userInfo = note.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        // Headphones unplugged: pause rather than blasting from the speaker.
        if reason == .oldDeviceUnavailable, state == .playing {
            pausePlayback()
        }
    }

    private func setupNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.networkIsCellular = path.usesInterfaceType(.cellular)
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "app.wave.network"))
    }
}
