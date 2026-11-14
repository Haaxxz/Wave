import Foundation

// MARK: - Playback engine contract

enum RepeatMode: Sendable {
    case off
    case all
    case one
}

enum PlayerState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case stopped
    case failed(String)
}

/// The player contract the UI binds to. Implemented by `Player`
/// (`Player.swift`), a `@MainActor @Observable` class. The UI never touches
/// AVFoundation directly — everything goes through this protocol.
@MainActor
protocol PlaybackEngine: AnyObject, Observable {
    var state: PlayerState { get }
    var currentTrack: Track? { get }
    var queue: [QueueItem] { get }
    var queueIndex: Int { get }
    var positionSeconds: Double { get }
    var durationSeconds: Double { get }
    var isShuffleEnabled: Bool { get set }
    var repeatMode: RepeatMode { get set }

    func play(_ track: Track)
    func playAll(_ tracks: [Track], startingAt index: Int)
    func togglePlayPause()
    func next()
    func previous()
    func seek(to seconds: Double)
    func addToQueue(_ track: Track)
    func removeFromQueue(at offsets: IndexSet)
    func moveQueue(from source: IndexSet, to destination: Int)
    func startRadio(for track: Track) async
}
