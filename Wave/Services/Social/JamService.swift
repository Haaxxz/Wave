import Foundation

// MARK: - Jam (Listen Together) service contract

/// A real-time listening room. Implemented by `JamClient` (`JamClient.swift`)
/// over `URLSessionWebSocketTask` to `wss://jam.clashgram.org/ws`, using the
/// same JSON protocol as the Android app (see `docs/SPECS.md`).
@MainActor
protocol JamService: AnyObject, Observable {
    var room: JamRoom? { get }
    var isConnected: Bool { get }

    /// Creates a room and returns its join code.
    func createRoom(name: String) async throws -> String
    func join(code: String) async throws
    func leave() async
    func sendPlay() async
    func sendPause() async
    func sendSeek(toMs: Int) async
    func sendQueueAdd(_ track: Track) async
}
