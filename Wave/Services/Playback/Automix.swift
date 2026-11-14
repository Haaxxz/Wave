import AVFoundation
import Foundation

// MARK: - Automix DJ transitions (simplified for iOS)
//
// What the Android app does: a C++ dual-deck DSP pipeline (Linkwitz-Riley
// crossover, LUFS contour normalisation, transient-preserving time stretch,
// phrase/loop synthesis) that beat-matches the outgoing and incoming tracks
// and crossfades them in the DSP domain.
//
// What this file does instead, honestly: the same user-visible behaviour —
// one track fades out while the next fades in, starting a few seconds before
// the outgoing track ends — implemented with two `AVAudioPlayerNode` decks
// in a single `AVAudioEngine`, with linear volume ramps. There is no
// beat-matching, no time-stretching and no phrase analysis: `Track` carries
// no tempo, so both tracks are assumed to be 120 BPM and the crossfade is
// delayed to the next beat boundary of the outgoing track (a 0.5 s grid),
// which keeps the transition from landing mid-beat without pretending to
// sync the two tracks' downbeats.
//
// The same engine also serves as the player's local-file / EQ / pitch path:
// normal playback runs on deck A, and the crossfade hands over to deck B.
// `Player` owns one `AutomixEngine` and uses it for every
// `AVAudioEngine`-backed track, so there is exactly one audio engine in the
// app (the streamed path uses `AVPlayer` instead — see `Player.swift`).

/// The dual-deck engine. All state is main-actor isolated because it is
/// managed by `Player` and AVFoundation callbacks are bridged back there.
@MainActor
final class AutomixEngine {
    /// How long a crossfade lasts, in seconds.
    var crossfadeDuration: TimeInterval = 8

    /// Tempo used for beat alignment when a track exposes none. `Track`
    /// has no tempo field, so this is always the value in practice.
    var defaultTempoBPM: Double = 120

    /// Resolves a track to a playable local audio file URL. Set by `Player`
    /// to its own resolver (local file first, otherwise the downloaded
    /// stream). `crossfade(to:)` uses it for the incoming track.
    var audioURLProvider: ((Track) async throws -> URL)?

    /// Called on the main actor when the active deck reaches the end of its
    /// file. `Player` advances the queue from here.
    var onTrackFinished: (() -> Void)?

    private let engine = AVAudioEngine()
    private let deckA = AVAudioPlayerNode()
    private let deckB = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let eq = AVAudioUnitEQ(numberOfBands: EQSettings.bandCount)

    private var activeDeck: AVAudioPlayerNode
    private var currentFile: AVAudioFile?
    private var currentTrack: Track?
    private var currentDuration: Double = 0
    /// Position offset (seconds) of the active deck's scheduled segment.
    private var basePosition: Double = 0
    private var endCheckTimer: Timer?
    private var engineStarted = false

    private(set) var isPlaying = false

    /// True while a crossfade ramp is running. `Player` skips its own
    /// end-of-track detection during this window.
    private(set) var isCrossfading = false

    init() {
        activeDeck = deckA
        engine.attach(deckA)
        engine.attach(deckB)
        engine.attach(timePitch)
        engine.attach(eq)
        // Both decks fan into the same time-pitch -> EQ chain; the engine
        // mixes them at the time-pitch input.
        engine.connect(deckA, to: timePitch, format: nil)
        engine.connect(deckB, to: timePitch, format: nil)
        engine.connect(timePitch, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
        deckA.volume = 1
        deckB.volume = 0
    }

    // MARK: - Position and duration

    var durationSeconds: Double { currentDuration }

    var positionSeconds: Double {
        guard isPlaying || basePosition > 0 else { return basePosition }
        guard let nodeTime = activeDeck.lastRenderTime,
              let playerTime = activeDeck.playerTime(forNodeTime: nodeTime) else {
            return basePosition
        }
        return basePosition + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    // MARK: - Engine lifecycle

    private func ensureEngineStarted() {
        guard !engineStarted else { return }
        engine.prepare()
        do {
            try engine.start()
            engineStarted = true
        } catch {
            // The engine will be retried on the next play call; playback
            // failures surface through Player's error handling instead.
            engineStarted = false
        }
    }

    // MARK: - Playback

    /// Plays a local audio file on deck A, replacing whatever was playing.
    /// Returns `false` when the file cannot be opened (unsupported
    /// container, e.g. Opus/WebM — the caller then falls back to streaming).
    @discardableResult
    func play(url: URL, track: Track) -> Bool {
        ensureEngineStarted()
        isCrossfading = false
        stopDecks()
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        currentFile = file
        currentTrack = track
        currentDuration = Double(file.length) / file.processingFormat.sampleRate
        basePosition = 0
        activeDeck = deckA
        deckA.volume = 1
        deckB.volume = 0
        deckA.scheduleFile(file, at: nil) { [weak self] in
            self?.fileDidFinish()
        }
        deckA.play()
        isPlaying = true
        startEndCheckTimer()
        return true
    }

    /// Resolves a track to a file URL via `audioURLProvider` and plays it.
    @discardableResult
    func play(track: Track) async throws -> Bool {
        guard let provider = audioURLProvider else { return false }
        let url = try await provider(track)
        return play(url: url, track: track)
    }

    func pause() {
        guard isPlaying else { return }
        if isCrossfading {
            // Snap the crossfade to its end state so there is exactly one
            // live deck: the incoming deck becomes active at full volume.
            // (The crossfade Task itself is owned by Player, which cancels
            // it; this just reconciles the deck state.)
            isCrossfading = false
            let incoming = activeDeck === deckA ? deckB : deckA
            activeDeck.stop()
            activeDeck.volume = 0
            activeDeck = incoming
            incoming.volume = 1
            basePosition = positionSeconds
        } else {
            basePosition = positionSeconds
        }
        deckA.pause()
        deckB.pause()
        isPlaying = false
        stopEndCheckTimer()
    }

    func resume() {
        guard !isPlaying, currentFile != nil else { return }
        ensureEngineStarted()
        if basePosition > 0, let file = currentFile {
            scheduleFromCurrentPosition(file: file)
        }
        activeDeck.play()
        isPlaying = true
        startEndCheckTimer()
    }

    func stop() {
        stopDecks()
        isCrossfading = false
        isPlaying = false
        currentFile = nil
        currentTrack = nil
        currentDuration = 0
        basePosition = 0
        stopEndCheckTimer()
    }

    func seek(to seconds: Double) {
        guard let file = currentFile, !isCrossfading else { return }
        let clamped = min(max(seconds, 0), currentDuration)
        let wasPlaying = isPlaying
        activeDeck.stop()
        basePosition = clamped
        scheduleFromCurrentPosition(file: file)
        if wasPlaying {
            activeDeck.play()
        }
    }

    // MARK: - Rate, pitch, EQ, volume

    /// `rate` is 0.5–2.0 (1.0 = normal). `pitchSemitones` shifts pitch
    /// without changing tempo, in semitones (0 = unchanged).
    func setRate(_ rate: Double, pitchSemitones: Double) {
        timePitch.rate = Float(min(max(rate, 0.25), 4.0))
        timePitch.pitch = Float(pitchSemitones * 100)
    }

    func applyEQ(_ settings: EQSettings, enabled: Bool) {
        if enabled {
            settings.apply(to: eq)
        } else {
            EQSettings.flat.apply(to: eq)
        }
    }

    /// Linear output volume multiplier (loudness normalisation lands here).
    func setVolume(_ volume: Float) {
        engine.mainMixerNode.outputVolume = volume
    }

    // MARK: - Crossfade

    /// Crossfades from the currently playing track to `next`. The incoming
    /// track is resolved through `audioURLProvider`, started on the idle
    /// deck, and ramped in over `crossfadeDuration` while the outgoing deck
    /// ramps out. The start is delayed to the next beat boundary of the
    /// outgoing track (120 BPM grid unless a tempo is known). Returns `true`
    /// when the ramp completed and the incoming track is the active deck,
    /// `false` when nothing was playing, the incoming track could not be
    /// resolved, or the crossfade was cancelled (the caller then falls back
    /// to a hard cut or lets the outgoing track end naturally).
    func crossfade(to next: Track) async -> Bool {
        guard isPlaying, let provider = audioURLProvider else { return false }
        guard let nextURL = try? await provider(next),
              let nextFile = try? AVAudioFile(forReading: nextURL) else { return false }
        guard !Task.isCancelled else { return false }

        let outgoing = activeDeck
        let incoming = outgoing === deckA ? deckB : deckA
        let nextDuration = Double(nextFile.length) / nextFile.processingFormat.sampleRate

        // Beat-align the start: wait for the next beat boundary of the
        // outgoing track (0.5 s grid at the 120 BPM default).
        let beatInterval = 60 / defaultTempoBPM
        let position = positionSeconds
        let delay = beatInterval - position.truncatingRemainder(dividingBy: beatInterval)
        if delay > 0.05, delay < beatInterval {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        guard !Task.isCancelled, isPlaying else { return false }

        isCrossfading = true
        incoming.volume = 0
        incoming.scheduleFile(nextFile, at: nil) { [weak self] in
            self?.fileDidFinish()
        }
        incoming.play()

        // The new track is now the reference for position/duration.
        currentFile = nextFile
        currentTrack = next
        currentDuration = nextDuration
        basePosition = 0

        let steps = 40
        let stepDuration = crossfadeDuration / Double(steps)
        for step in 1...steps {
            if Task.isCancelled { break }
            let t = Double(step) / Double(steps)
            outgoing.volume = Float(1 - t)
            incoming.volume = Float(t)
            try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
        }
        guard !Task.isCancelled else {
            // Cancelled mid-ramp (pause / skip / new track): leave the
            // decks as they are — Player reconciles them via pause/stop —
            // and report failure so the queue is not advanced.
            isCrossfading = false
            return false
        }
        outgoing.stop()
        outgoing.volume = 0
        incoming.volume = 1
        activeDeck = incoming
        isCrossfading = false
        return true
    }

    // MARK: - Private

    private func stopDecks() {
        deckA.stop()
        deckB.stop()
        deckA.volume = 1
        deckB.volume = 0
    }

    private func scheduleFromCurrentPosition(file: AVAudioFile) {
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(basePosition * sampleRate)
        let remaining = file.length - startFrame
        guard remaining > 0 else { return }
        activeDeck.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining), at: nil) { [weak self] in
            self?.fileDidFinish()
        }
    }

    private func fileDidFinish() {
        // Fires on an audio thread; hop to the main actor for the callback.
        Task { @MainActor [weak self] in
            guard let self, self.isPlaying, !self.isCrossfading else { return }
            self.isPlaying = false
            self.onTrackFinished?()
        }
    }

    private func startEndCheckTimer() {
        stopEndCheckTimer()
        endCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            // The node completion handler is the primary signal; the timer
            // is a backstop for files whose completion never fires.
            guard self.isPlaying, !self.isCrossfading, self.currentDuration > 0 else { return }
            if self.positionSeconds >= self.currentDuration - 0.05 {
                self.isPlaying = false
                self.stopEndCheckTimer()
                Task { @MainActor in
                    self.onTrackFinished?()
                }
            }
        }
    }

    private func stopEndCheckTimer() {
        endCheckTimer?.invalidate()
        endCheckTimer = nil
    }
}
