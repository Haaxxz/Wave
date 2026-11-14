import Foundation

// MARK: - Jam protocol types
//
// Verbatim port of the Android app's `data/jam/JamProtocol.kt` and the
// behaviour in `data/jam/JamRepository.kt` + `playback/jam/JamPlaybackSync.kt`.
//
// Wire format: every WebSocket frame is a JSON envelope
// `{"type": "<message>", "payload": {...}}`. Message names, payload fields
// and defaults are copied from the Android source — this client speaks the
// same protocol as the Android app against `wss://jam.clashgram.org/ws`
// (HTTP base `https://jam.clashgram.org`, invite links
// `https://jam.clashgram.org/?code=ABC123`, deep links `wave://jam?code=…`).
//
// Playback sync rules (from JamPlaybackSync): only the host — or anyone in a
// collaborative room — may control playback; events from yourself are
// ignored; after applying a remote event (or broadcasting a local one) the
// client stays quiet for ~800 ms so the echo does not bounce back; remote
// play positions are latency-compensated with the server timestamp (capped
// at 5 s); a seek is only applied when local and remote positions differ by
// more than 2 s; live stations (INDIA/WORLD) rejoin the live position every
// 2 s for non-host listeners.

enum JamMessageType {
    // Client -> server
    static let createRoom = "create_room"
    static let joinRoom = "join_room"
    static let leaveRoom = "leave_room"
    static let sendChat = "send_chat"
    static let playbackAction = "playback_action"
    static let ping = "ping"
    static let grantHost = "grant_host"
    static let transferHost = "transfer_host"
    static let revokeHost = "revoke_host"
    static let stationMode = "station_mode"
    static let queueUpdate = "queue_update"
    static let cooldown = "cooldown"
    static let queueUpdated = "queue_updated"
    static let changeRoomMode = "change_room_mode"

    // Server -> client
    static let roomCreated = "room_created"
    static let syncState = "sync_state"
    static let userJoined = "user_joined"
    static let userLeft = "user_left"
    static let chatMessage = "chat_message"
    static let syncPlayback = "sync_playback"
    static let hostChanged = "host_changed"
    static let cohostChanged = "cohost_changed"
    static let roomModeChanged = "room_mode_changed"
    static let stationModeUpdate = "station_mode"
    static let pong = "pong"
    static let error = "error"
}

enum JamPlaybackAction {
    static let play = "play"
    static let pause = "pause"
    static let seek = "seek"
    static let skipNext = "skip_next"
    static let changeTrack = "change_track"
    static let queueAdd = "queue_add"
}

enum JamRoomMode {
    static let hostOnly = "host_only"
    static let collaborative = "collaborative"
}

/// Always-on stations provisioned by the server.
struct JamStation {
    var code: String
    var title: String
    var blurb: String
}

let jamStations: [JamStation] = [
    JamStation(code: "INDIA", title: "India", blurb: "Always-on room for India"),
    JamStation(code: "WORLD", title: "International", blurb: "Always-on room for everyone else"),
]

/// Accepts a bare room code or a pasted invite link (`...?code=ABC123`).
func parseJamCode(_ raw: String) -> String {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let tail: String
    if let range = text.range(of: "code=", options: .caseInsensitive) {
        tail = String(text[range.upperBound...])
    } else {
        tail = text
    }
    return String(tail.prefix(while: { $0 != "&" && $0 != "#" && !$0.isWhitespace })).uppercased()
}

// MARK: Envelope + payloads

/// A typed envelope. The client encodes these to send; incoming frames are
/// parsed generically (see `JamClient.handleMessage`) because the payload
/// shape depends on `type`.
struct JamEnvelope<Payload: Codable>: Codable {
    var type: String
    var payload: Payload?

    init(type: String, payload: Payload? = nil) {
        self.type = type
        self.payload = payload
    }
}

struct CreateRoomRequest: Codable {
    var name: String
    var roomMode: String = JamRoomMode.collaborative

    enum CodingKeys: String, CodingKey {
        case name
        case roomMode = "room_mode"
    }

    init(name: String, roomMode: String = JamRoomMode.collaborative) {
        self.name = name
        self.roomMode = roomMode
    }
}

struct JoinRoomRequest: Codable {
    var roomCode: String
    var name: String

    enum CodingKeys: String, CodingKey {
        case roomCode = "room_code"
        case name
    }
}

struct SendChatRequest: Codable {
    var text: String
    var replyToId: String?

    enum CodingKeys: String, CodingKey {
        case text
        case replyToId = "reply_to_id"
    }
}

struct GrantHostRequest: Codable {
    var userId: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }
}

struct ChangeRoomModeRequest: Codable {
    var roomMode: String

    enum CodingKeys: String, CodingKey {
        case roomMode = "room_mode"
    }
}

struct QueueUpdateRequest: Codable {
    var queue: [TrackInfoPayload]
}

struct CooldownPayload: Codable {
    var retryAtMs: Int64 = 0
    var windowMs: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case retryAtMs = "retry_at_ms"
        case windowMs = "window_ms"
    }

    init(retryAtMs: Int64 = 0, windowMs: Int64 = 0) {
        self.retryAtMs = retryAtMs
        self.windowMs = windowMs
    }
}

struct RoomInfoPayload: Codable {
    var code: String = ""
    var name: String = ""
    var participants: Int = 0

    init(code: String = "", name: String = "", participants: Int = 0) {
        self.code = code
        self.name = name
        self.participants = participants
    }
}

struct RoomsResponse: Codable {
    var rooms: [RoomInfoPayload]

    init(rooms: [RoomInfoPayload] = []) {
        self.rooms = rooms
    }
}

struct QueueUpdatedPayload: Codable {
    var queue: [TrackInfoPayload] = []
    var hostId: String = ""

    enum CodingKeys: String, CodingKey {
        case queue
        case hostId = "host_id"
    }

    init(queue: [TrackInfoPayload] = [], hostId: String = "") {
        self.queue = queue
        self.hostId = hostId
    }
}

struct StationModePayload: Codable {
    var auto: Bool = true
    var adminId: String = ""
    var adminName: String = ""

    enum CodingKeys: String, CodingKey {
        case auto
        case adminId = "admin_id"
        case adminName = "admin_name"
    }

    init(auto: Bool = true, adminId: String = "", adminName: String = "") {
        self.auto = auto
        self.adminId = adminId
        self.adminName = adminName
    }
}

struct RoomCreatedPayload: Codable {
    var roomCode: String
    var userId: String
    var name: String = ""
    var isHost: Bool = true
    var roomMode: String = JamRoomMode.collaborative

    enum CodingKeys: String, CodingKey {
        case roomCode = "room_code"
        case userId = "user_id"
        case name
        case isHost = "is_host"
        case roomMode = "room_mode"
    }

    init(roomCode: String, userId: String, name: String = "", isHost: Bool = true, roomMode: String = JamRoomMode.collaborative) {
        self.roomCode = roomCode
        self.userId = userId
        self.name = name
        self.isHost = isHost
        self.roomMode = roomMode
    }
}

struct ParticipantPayload: Codable {
    var userId: String = ""
    var name: String = ""
    var isHost: Bool = false
    var isCoHost: Bool = false
    var joinedAt: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name
        case isHost = "is_host"
        case isCoHost = "is_cohost"
        case joinedAt = "joined_at"
    }

    init(userId: String = "", name: String = "", isHost: Bool = false, isCoHost: Bool = false, joinedAt: Int64 = 0) {
        self.userId = userId
        self.name = name
        self.isHost = isHost
        self.isCoHost = isCoHost
        self.joinedAt = joinedAt
    }
}

struct HostChangedPayload: Codable {
    var newHostId: String = ""
    var newHostName: String = ""
    var userId: String = ""
    var name: String = ""
    var hostId: String = ""
    var coHostId: String = ""

    enum CodingKeys: String, CodingKey {
        case newHostId = "new_host_id"
        case newHostName = "new_host_name"
        case userId = "user_id"
        case name
        case hostId = "host_id"
        case coHostId = "cohost_id"
    }

    init(newHostId: String = "", newHostName: String = "", userId: String = "", name: String = "", hostId: String = "", coHostId: String = "") {
        self.newHostId = newHostId
        self.newHostName = newHostName
        self.userId = userId
        self.name = name
        self.hostId = hostId
        self.coHostId = coHostId
    }

    var effectiveHostId: String {
        hostId.isEmpty ? (newHostId.isEmpty ? userId : newHostId) : hostId
    }

    var effectiveHostName: String {
        newHostName.isEmpty ? name : newHostName
    }
}

struct CoHostChangedPayload: Codable {
    var hostId: String = ""
    var coHostId: String = ""
    var coHostName: String = ""

    enum CodingKeys: String, CodingKey {
        case hostId = "host_id"
        case coHostId = "cohost_id"
        case coHostName = "cohost_name"
    }

    init(hostId: String = "", coHostId: String = "", coHostName: String = "") {
        self.hostId = hostId
        self.coHostId = coHostId
        self.coHostName = coHostName
    }
}

struct UserLeftPayload: Codable {
    var userId: String = ""
    var name: String = ""
    var isHost: Bool = false
    var totalUsers: Int = 0

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name
        case isHost = "is_host"
        case totalUsers = "total_users"
    }

    init(userId: String = "", name: String = "", isHost: Bool = false, totalUsers: Int = 0) {
        self.userId = userId
        self.name = name
        self.isHost = isHost
        self.totalUsers = totalUsers
    }
}

struct RoomModeChangedPayload: Codable {
    var roomMode: String = JamRoomMode.collaborative
    var changedBy: String = ""

    enum CodingKeys: String, CodingKey {
        case roomMode = "room_mode"
        case changedBy = "changed_by"
    }

    init(roomMode: String = JamRoomMode.collaborative, changedBy: String = "") {
        self.roomMode = roomMode
        self.changedBy = changedBy
    }
}

struct ChatReplyPayload: Codable {
    var id: String = ""
    var userId: String = ""
    var userName: String = ""
    var text: String = ""

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case userName = "user_name"
        case text
    }

    init(id: String = "", userId: String = "", userName: String = "", text: String = "") {
        self.id = id
        self.userId = userId
        self.userName = userName
        self.text = text
    }
}

struct ChatMessagePayload: Codable {
    var id: String = ""
    var userId: String = ""
    var userName: String = ""
    var isHost: Bool = false
    var text: String = ""
    var timestamp: Int64 = 0
    var replyTo: ChatReplyPayload?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case userName = "user_name"
        case isHost = "is_host"
        case text
        case timestamp
        case replyTo = "reply_to"
    }

    init(id: String = "", userId: String = "", userName: String = "", isHost: Bool = false, text: String = "", timestamp: Int64 = 0, replyTo: ChatReplyPayload? = nil) {
        self.id = id
        self.userId = userId
        self.userName = userName
        self.isHost = isHost
        self.text = text
        self.timestamp = timestamp
        self.replyTo = replyTo
    }
}

struct TrackInfoPayload: Codable {
    var id: String
    var title: String
    var artist: String
    var album: String?
    var artworkUrl: String?
    var durationMs: Int64?
    var source: String?
    var suggestedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case album
        case artworkUrl = "artwork_url"
        case durationMs = "duration_ms"
        case source
        case suggestedBy = "suggested_by"
    }

    init(id: String, title: String, artist: String, album: String? = nil, artworkUrl: String? = nil, durationMs: Int64? = nil, source: String? = nil, suggestedBy: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkUrl = artworkUrl
        self.durationMs = durationMs
        self.source = source
        self.suggestedBy = suggestedBy
    }

    /// Builds the payload the Android client sends: the YouTube video id (or
    /// the title when there is none), title, artist, album, artwork and
    /// duration. `source` is left unset, as in the Android client.
    init(track: Track) {
        self.id = track.id.isEmpty ? track.title : track.id
        self.title = track.title
        self.artist = track.artistNames
        self.album = track.album?.title
        self.artworkUrl = track.artworkURL?.absoluteString
        self.durationMs = track.durationSeconds.map { Int64($0) * 1_000 }
        self.source = nil
        self.suggestedBy = nil
    }

    /// Back to a playable `Track`. The id is the YouTube video id, so the
    /// player resolves it through InnerTube like any other track.
    func toTrack() -> Track {
        Track(
            id: id,
            title: title,
            artists: [ArtistRef(id: "", name: artist)],
            album: album.map { AlbumRef(id: "", title: $0) },
            durationSeconds: durationMs.map { Int($0 / 1_000) },
            thumbnails: artworkUrl.flatMap(URL.init).map { [Thumbnail(url: $0)] } ?? []
        )
    }
}

struct PlaybackActionPayload: Codable {
    var action: String
    var fromUserId: String?
    var track: TrackInfoPayload?
    var positionMs: Int64 = 0
    var clientTimeMs: Int64?
    var serverTimeMs: Int64 = 0
    var isPlaying: Bool = false
    var queue: [TrackInfoPayload]?
    var revision: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case action
        case fromUserId = "from_user_id"
        case track
        case positionMs = "position_ms"
        case clientTimeMs = "client_time_ms"
        case serverTimeMs = "server_time_ms"
        case isPlaying = "is_playing"
        case queue
        case revision
    }

    init(
        action: String,
        fromUserId: String? = nil,
        track: TrackInfoPayload? = nil,
        positionMs: Int64 = 0,
        clientTimeMs: Int64? = nil,
        serverTimeMs: Int64 = 0,
        isPlaying: Bool = false,
        queue: [TrackInfoPayload]? = nil,
        revision: Int64 = 0
    ) {
        self.action = action
        self.fromUserId = fromUserId
        self.track = track
        self.positionMs = positionMs
        self.clientTimeMs = clientTimeMs
        self.serverTimeMs = serverTimeMs
        self.isPlaying = isPlaying
        self.queue = queue
        self.revision = revision
    }
}

struct PlaybackStatePayload: Codable {
    var currentTrack: TrackInfoPayload?
    var positionMs: Int64 = 0
    var serverTimeMs: Int64 = 0
    var isPlaying: Bool = false
    var queue: [TrackInfoPayload] = []
    var revision: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case currentTrack = "current_track"
        case positionMs = "position_ms"
        case serverTimeMs = "server_time_ms"
        case isPlaying = "is_playing"
        case queue
        case revision
    }

    init(currentTrack: TrackInfoPayload? = nil, positionMs: Int64 = 0, serverTimeMs: Int64 = 0, isPlaying: Bool = false, queue: [TrackInfoPayload] = [], revision: Int64 = 0) {
        self.currentTrack = currentTrack
        self.positionMs = positionMs
        self.serverTimeMs = serverTimeMs
        self.isPlaying = isPlaying
        self.queue = queue
        self.revision = revision
    }
}

struct SyncStatePayload: Codable {
    var roomCode: String
    var userId: String
    var name: String
    var isHost: Bool
    var hostId: String = ""
    var coHostId: String = ""
    var permanent: Bool = false
    var roomName: String = ""
    var radio: Bool = false
    var stationAuto: Bool = true
    var roomMode: String = JamRoomMode.collaborative
    var playback: PlaybackStatePayload
    var participants: [ParticipantPayload] = []
    var chatHistory: [ChatMessagePayload] = []

    enum CodingKeys: String, CodingKey {
        case roomCode = "room_code"
        case userId = "user_id"
        case name
        case isHost = "is_host"
        case hostId = "host_id"
        case coHostId = "cohost_id"
        case permanent
        case roomName = "room_name"
        case radio
        case stationAuto = "station_auto"
        case roomMode = "room_mode"
        case playback
        case participants
        case chatHistory = "chat_history"
    }
}

struct ErrorPayload: Codable {
    var code: String = ""
    var message: String = ""
    var retryAfterMs: Int64 = 0
    var retryAtMs: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case retryAfterMs = "retry_after_ms"
        case retryAtMs = "retry_at_ms"
    }

    init(code: String = "", message: String = "", retryAfterMs: Int64 = 0, retryAtMs: Int64 = 0) {
        self.code = code
        self.message = message
        self.retryAfterMs = retryAfterMs
        self.retryAtMs = retryAtMs
    }
}

// MARK: - Client

enum JamError: Error, LocalizedError {
    case notConnected
    case timeout
    case invalidCode
    case serverError(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to a Jam room"
        case .timeout: return "The Jam server did not answer in time"
        case .invalidCode: return "Enter a room code to join"
        case .serverError(let message): return message
        case .connectionFailed(let message): return "Could not reach the Jam server: \(message)"
        }
    }
}

/// A real-time listening room ("Listen Together") over
/// `URLSessionWebSocketTask` to `wss://jam.clashgram.org/ws`, speaking the
/// same JSON protocol as the Android app. iOS suspends sockets when the app
/// backgrounds; the socket stays alive while audio plays (background audio
/// mode). Reconnects up to 3 times on an unexpected drop while in a room.
@MainActor
@Observable
final class JamClient: JamService {
    static let shared = JamClient(player: Player.shared)

    static let serverWebSocketURL = URL(string: "wss://jam.clashgram.org/ws")!
    static let serverHTTPBase = "https://jam.clashgram.org"
    private static let joinTimeoutSeconds: Double = 15
    private static let pingIntervalNanoseconds: UInt64 = 25_000_000_000
    private static let maxReconnectAttempts = 3
    private static let driftSeekThresholdMs: Int64 = 2_000
    private static let maxLatencyCompensationMs: Int64 = 5_000
    private static let liveDriftThresholdMs: Int64 = 4_000

    private let player: Player
    private let settings: SettingsStore

    var room: JamRoom?
    var isConnected: Bool = false

    /// Chat history of the current room (newest last, capped at 50).
    var chatMessages: [ChatMessagePayload] = []
    /// The host's upcoming queue, shared read-only.
    var roomQueue: [TrackInfoPayload] = []
    /// Wall-clock ms until which pause/skip are locked for you; 0 when free.
    var cooldownUntilMs: Int64 = 0
    /// A rejected request inside a room (rate limit, host rules).
    var notice: String?
    /// True when you are the room's main host or a co-host.
    var isHost: Bool = false
    var roomMode: String = JamRoomMode.collaborative
    /// True when the room is a 24/7 live station.
    var isStationRadio: Bool = false
    var userId: String = ""

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var liveEnforcementTask: Task<Void, Never>?
    private var joinContinuation: CheckedContinuation<Void, Error>?
    private var reconnectAttempts = 0
    private var intentionalDisconnect = false
    private var pendingIntent: PendingIntent?
    private var quietUntil: Date = .distantPast
    private var lastBroadcastTrackId: String?
    private var lastBroadcastIsPlaying: Bool?
    private var lastBroadcastPositionMs: Int64 = 0
    private var lastPolledPositionMs: Int64 = 0
    private var lastPollTime: Date = Date()
    private var lastPublishedQueueIds: [String] = []
    private var liveTrack: TrackInfoPayload?
    private var livePositionMs: Int64 = 0
    private var liveIsPlaying: Bool = false
    private var liveAt: Date = Date()

    private enum PendingIntent {
        case create(name: String)
        case join(code: String, name: String)
    }

    init(player: Player, settings: SettingsStore = .shared) {
        self.player = player
        self.settings = settings
    }

    private var displayName: String {
        let name = settings.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Listener" : name
    }

    // MARK: - JamService

    func createRoom(name: String) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "Listener" : trimmed
        pendingIntent = .create(name: display)
        await connect()
        try await waitForJoin()
        guard let code = room?.code, !code.isEmpty else { throw JamError.timeout }
        return code
    }

    func join(code: String) async throws {
        let parsed = parseJamCode(code)
        guard !parsed.isEmpty else { throw JamError.invalidCode }
        let name = displayName
        if jamStations.contains(where: { $0.code == parsed }),
           ["", "listener", "host", "guest", "user", "anonymous"].contains(name.lowercased()) {
            throw JamError.serverError("Pick your own display name to join this public room")
        }
        pendingIntent = .join(code: parsed, name: name)
        await connect()
        try await waitForJoin()
    }

    func leave() async {
        await sendEnvelope(JamEnvelope<EmptyPayload>(type: JamMessageType.leaveRoom))
        disconnect(intentional: true)
    }

    func sendPlay() async {
        await broadcastPlaybackAction(.init(
            action: JamPlaybackAction.play,
            positionMs: currentPositionMs(),
            clientTimeMs: nowMs(),
            isPlaying: true
        ))
    }

    func sendPause() async {
        await broadcastPlaybackAction(.init(
            action: JamPlaybackAction.pause,
            positionMs: currentPositionMs(),
            clientTimeMs: nowMs(),
            isPlaying: false
        ))
    }

    func sendSeek(toMs: Int) async {
        await broadcastPlaybackAction(.init(
            action: JamPlaybackAction.seek,
            positionMs: Int64(toMs),
            clientTimeMs: nowMs()
        ))
    }

    func sendQueueAdd(_ track: Track) async {
        player.addToQueue(track)
        await broadcastPlaybackAction(.init(
            action: JamPlaybackAction.queueAdd,
            track: TrackInfoPayload(track: track),
            positionMs: currentPositionMs(),
            clientTimeMs: nowMs(),
            isPlaying: player.state == .playing
        ))
    }

    // MARK: - Extras for the UI

    /// Shareable invite link. Opens the web invite page, which launches
    /// whichever LastWave/Wave app is installed.
    func inviteLink(code: String) -> String {
        "\(Self.serverHTTPBase)/?code=\(code)"
    }

    /// Live listener counts for the always-on rooms ({code: count}).
    /// Empty on any failure, so the join screen just omits the counts.
    func fetchRoomCounts() async -> [String: Int] {
        guard let url = URL(string: Self.serverHTTPBase + "/rooms") else { return [:] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [:] }
            let decoded = try JSONDecoder().decode(RoomsResponse.self, from: data)
            return Dictionary(uniqueKeysWithValues: decoded.rooms.map { ($0.code, $0.participants) })
        } catch {
            return [:]
        }
    }

    /// Sends a chat message to the room.
    func sendChat(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await sendEnvelope(JamEnvelope(type: JamMessageType.sendChat, payload: SendChatRequest(text: trimmed)))
    }

    /// Host only: publish the upcoming queue so listeners can see it.
    func publishQueue(_ queue: [TrackInfoPayload]) async {
        guard room != nil else { return }
        await sendEnvelope(JamEnvelope(type: JamMessageType.queueUpdate, payload: QueueUpdateRequest(queue: Array(queue.prefix(5)))))
    }

    // MARK: - Connection

    private func connect() async {
        disconnect(intentional: true)
        intentionalDisconnect = false
        reconnectAttempts = 0
        let task = URLSession.shared.webSocketTask(with: Self.serverWebSocketURL)
        webSocketTask = task
        task.resume()
        isConnected = true
        startReceiveLoop()
        startPingLoop()
        startPlayerObservation()
        startLiveEnforcement()
        // The create/join request goes out once the socket opens; the receive
        // loop's first task is to flush it. `URLSessionWebSocketTask` has no
        // on-open callback, so send immediately — the task buffers until the
        // handshake completes.
        await sendPendingIntent()
    }

    private func sendPendingIntent() async {
        switch pendingIntent {
        case .create(let name):
            await sendEnvelope(JamEnvelope(
                type: JamMessageType.createRoom,
                payload: CreateRoomRequest(name: name)
            ))
        case .join(let code, let name):
            await sendEnvelope(JamEnvelope(
                type: JamMessageType.joinRoom,
                payload: JoinRoomRequest(roomCode: code, name: name)
            ))
        case .none:
            break
        }
    }

    private func disconnect(intentional: Bool) {
        intentionalDisconnect = intentional
        receiveTask?.cancel()
        pingTask?.cancel()
        observationTask?.cancel()
        liveEnforcementTask?.cancel()
        receiveTask = nil
        pingTask = nil
        observationTask = nil
        liveEnforcementTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        room = nil
        chatMessages = []
        roomQueue = []
        cooldownUntilMs = 0
        notice = nil
        isHost = false
        isStationRadio = false
        userId = ""
        lastBroadcastTrackId = nil
        lastBroadcastIsPlaying = nil
        lastPublishedQueueIds = []
        liveTrack = nil
    }

    private func waitForJoin() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            joinContinuation = continuation
            Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.joinTimeoutSeconds * 1_000_000_000))
                self.resumeJoinContinuation(with: .failure(JamError.timeout))
            }
        }
    }

    private func resumeJoinContinuation(with result: Result<Void, Error>) {
        guard let continuation = joinContinuation else { return }
        joinContinuation = nil
        continuation.resume(with: result)
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = self.webSocketTask else { return }
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        await self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        await self.handleSocketClosed(error: error)
                    }
                    return
                }
            }
        }
    }

    private func startPingLoop() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pingIntervalNanoseconds)
                if Task.isCancelled { return }
                await self.sendEnvelope(JamEnvelope<EmptyPayload>(type: JamMessageType.ping))
            }
        }
    }

    private func handleSocketClosed(error: Error) async {
        webSocketTask = nil
        isConnected = false
        guard !intentionalDisconnect, room != nil, reconnectAttempts < Self.maxReconnectAttempts else {
            if room != nil { disconnect(intentional: true) }
            resumeJoinContinuation(with: .failure(JamError.connectionFailed(error.localizedDescription)))
            return
        }
        reconnectAttempts += 1
        let backoff = UInt64(reconnectAttempts) * 1_000_000_000
        try? await Task.sleep(nanoseconds: backoff)
        guard !intentionalDisconnect, room != nil else { return }
        let task = URLSession.shared.webSocketTask(with: Self.serverWebSocketURL)
        webSocketTask = task
        task.resume()
        isConnected = true
        startReceiveLoop()
        startPingLoop()
        await sendPendingIntent()
    }

    // MARK: - Incoming messages

    private func handleMessage(_ text: String) async {
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        switch type {
        case JamMessageType.roomCreated:
            guard let payload = decodePayload(RoomCreatedPayload.self, from: json) else { return }
            userId = payload.userId
            isHost = true
            roomMode = payload.roomMode
            room = JamRoom(
                code: payload.roomCode,
                name: payload.name.isEmpty ? "Jam" : payload.name,
                hostName: payload.name.isEmpty ? "Host" : payload.name,
                members: [payload.name.isEmpty ? "Host" : payload.name]
            )
            resumeJoinContinuation(with: .success(()))

        case JamMessageType.syncState:
            guard let payload = decodePayload(SyncStatePayload.self, from: json) else { return }
            userId = payload.userId
            isHost = payload.isHost
            roomMode = payload.roomMode
            isStationRadio = payload.radio
            room = JamRoom(
                code: payload.roomCode,
                name: payload.roomName.isEmpty ? payload.name : payload.roomName,
                hostName: payload.participants.first(where: { $0.isHost })?.name ?? payload.name,
                members: payload.participants.map(\.name),
                currentTrack: payload.playback.currentTrack?.toTrack(),
                positionMs: Int(payload.playback.positionMs),
                isPlaying: payload.playback.isPlaying
            )
            roomQueue = payload.playback.queue
            chatMessages = Array(payload.chatHistory.suffix(50))
            noteLive(playback: payload.playback)
            await applyPlaybackState(payload.playback)
            resumeJoinContinuation(with: .success(()))

        case JamMessageType.userJoined:
            guard let payload = decodePayload(ParticipantPayload.self, from: json) else { return }
            guard var current = room else { return }
            if !current.members.contains(payload.name) {
                current.members.append(payload.name)
                room = current
            }

        case JamMessageType.userLeft:
            guard let payload = decodePayload(UserLeftPayload.self, from: json) else { return }
            guard var current = room else { return }
            current.members.removeAll { $0 == payload.name }
            room = current

        case JamMessageType.hostChanged:
            guard let payload = decodePayload(HostChangedPayload.self, from: json) else { return }
            isHost = payload.effectiveHostId == userId
            if var current = room {
                current.hostName = payload.effectiveHostName
                room = current
            }

        case JamMessageType.cohostChanged:
            guard let payload = decodePayload(CoHostChangedPayload.self, from: json) else { return }
            isHost = payload.hostId == userId || payload.coHostId == userId

        case JamMessageType.roomModeChanged:
            guard let payload = decodePayload(RoomModeChangedPayload.self, from: json) else { return }
            roomMode = payload.roomMode

        case JamMessageType.stationModeUpdate:
            guard let payload = decodePayload(StationModePayload.self, from: json) else { return }
            isStationRadio = payload.auto

        case JamMessageType.cooldown:
            guard let payload = decodePayload(CooldownPayload.self, from: json) else { return }
            cooldownUntilMs = payload.retryAtMs

        case JamMessageType.queueUpdated:
            guard let payload = decodePayload(QueueUpdatedPayload.self, from: json) else { return }
            roomQueue = payload.queue

        case JamMessageType.chatMessage:
            guard let payload = decodePayload(ChatMessagePayload.self, from: json) else { return }
            chatMessages.append(payload)
            chatMessages = Array(chatMessages.suffix(50))

        case JamMessageType.syncPlayback:
            guard let payload = decodePayload(PlaybackActionPayload.self, from: json) else { return }
            await applyPlaybackAction(payload)

        case JamMessageType.error:
            guard let payload = decodePayload(ErrorPayload.self, from: json) else { return }
            let message = payload.message.isEmpty ? "Unknown server error" : payload.message
            if room != nil {
                // A rejected request inside a room must not eject you from it.
                notice = message
                if payload.code == "rate_limited" {
                    let retryAt = payload.retryAtMs > 0
                        ? payload.retryAtMs
                        : nowMs() + payload.retryAfterMs
                    cooldownUntilMs = retryAt
                }
            } else {
                resumeJoinContinuation(with: .failure(JamError.serverError(message)))
                disconnect(intentional: true)
            }

        case JamMessageType.pong:
            break

        default:
            break
        }
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, from json: [String: Any]) -> T? {
        guard let payload = json["payload"] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Outgoing

    private struct EmptyPayload: Codable {}

    private func sendEnvelope<Payload: Codable>(_ envelope: JamEnvelope<Payload>) async {
        guard let task = webSocketTask, isConnected else { return }
        do {
            let data = try JSONEncoder().encode(envelope)
            guard let text = String(data: data, encoding: .utf8) else { return }
            try await task.send(.string(text))
        } catch {
            // A failed send on a dying socket is handled by the receive loop.
        }
    }

    private func broadcastPlaybackAction(_ action: PlaybackActionPayload) async {
        guard room != nil, isConnected else { return }
        await sendEnvelope(JamEnvelope(type: JamMessageType.playbackAction, payload: action))
    }

    // MARK: - Applying remote playback

    private func applyPlaybackAction(_ action: PlaybackActionPayload) async {
        guard room != nil else { return }
        // Echo loop suppression: ignore events that originated from ourselves.
        if let from = action.fromUserId, !from.isEmpty, from == userId { return }
        noteLive(action: action)
        switch action.action {
        case JamPlaybackAction.play:
            let target = latencyCompensatedPosition(action.positionMs, serverTimeMs: action.serverTimeMs)
            await applyPlay(positionMs: target)
        case JamPlaybackAction.pause:
            await applyPause(positionMs: action.positionMs)
        case JamPlaybackAction.seek:
            await applySeek(positionMs: action.positionMs)
        case JamPlaybackAction.changeTrack:
            if let track = action.track {
                await applyTrackChange(track, positionMs: action.positionMs, isPlaying: action.isPlaying)
            }
        case JamPlaybackAction.queueAdd:
            if let track = action.track {
                player.addToQueue(track.toTrack())
            }
        default:
            break
        }
    }

    private func applyPlaybackState(_ state: PlaybackStatePayload) async {
        guard let track = state.currentTrack else { return }
        let target = latencyCompensatedPosition(state.positionMs, serverTimeMs: state.serverTimeMs)
        await applyTrackChange(track, positionMs: target, isPlaying: state.isPlaying)
    }

    private func latencyCompensatedPosition(_ positionMs: Int64, serverTimeMs: Int64) -> Int64 {
        let now = nowMs()
        let latency: Int64 = (serverTimeMs > 0 && now > serverTimeMs)
            ? min(now - serverTimeMs, Self.maxLatencyCompensationMs)
            : 0
        return max(0, positionMs + latency)
    }

    private func applyPlay(positionMs: Int64) async {
        quietUntil = Date().addingTimeInterval(0.8)
        if player.currentTrack == nil, let current = room?.currentTrack {
            await applyTrackChange(TrackInfoPayload(track: current), positionMs: positionMs, isPlaying: true)
            return
        }
        let currentMs = currentPositionMs()
        if abs(currentMs - positionMs) > Self.driftSeekThresholdMs {
            player.seek(to: Double(positionMs) / 1_000)
        }
        if player.state != .playing {
            player.togglePlayPause()
        }
    }

    private func applyPause(positionMs: Int64) async {
        quietUntil = Date().addingTimeInterval(0.8)
        if player.state == .playing {
            player.togglePlayPause()
        }
        if positionMs >= 0 {
            let currentMs = currentPositionMs()
            if abs(currentMs - positionMs) > Self.driftSeekThresholdMs {
                player.seek(to: Double(positionMs) / 1_000)
            }
        }
    }

    private func applySeek(positionMs: Int64) async {
        quietUntil = Date().addingTimeInterval(0.8)
        let currentMs = currentPositionMs()
        if abs(currentMs - positionMs) > Self.driftSeekThresholdMs {
            player.seek(to: Double(positionMs) / 1_000)
        }
    }

    private func applyTrackChange(_ track: TrackInfoPayload, positionMs: Int64, isPlaying: Bool) async {
        quietUntil = Date().addingTimeInterval(0.8)
        let model = track.toTrack()
        player.play(model)
        // The player resolves the stream asynchronously; seek once it has
        // had a moment to load, then match the room's play state.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if positionMs > 0 {
            player.seek(to: Double(positionMs) / 1_000)
        }
        if !isPlaying, player.state == .playing {
            player.togglePlayPause()
        } else if isPlaying, player.state != .playing {
            player.togglePlayPause()
        }
        lastBroadcastTrackId = model.id
        lastBroadcastIsPlaying = isPlaying
    }

    /// Remembers where the live station is, from every server playback event.
    private func noteLive(action: PlaybackActionPayload) {
        switch action.action {
        case JamPlaybackAction.changeTrack:
            liveTrack = action.track
            livePositionMs = action.positionMs
            liveIsPlaying = action.isPlaying
        case JamPlaybackAction.play:
            livePositionMs = latencyCompensatedPosition(action.positionMs, serverTimeMs: action.serverTimeMs)
            liveIsPlaying = true
        case JamPlaybackAction.pause:
            livePositionMs = action.positionMs
            liveIsPlaying = false
        case JamPlaybackAction.seek:
            livePositionMs = action.positionMs
        default:
            break
        }
        liveAt = Date()
    }

    private func noteLive(playback: PlaybackStatePayload) {
        liveTrack = playback.currentTrack
        livePositionMs = latencyCompensatedPosition(playback.positionMs, serverTimeMs: playback.serverTimeMs)
        liveIsPlaying = playback.isPlaying
        liveAt = Date()
    }

    // MARK: - Broadcasting local playback (JamPlaybackSync equivalent)

    private func startPlayerObservation() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                await self.pollPlayerState()
            }
        }
    }

    private func pollPlayerState() async {
        guard room != nil, isConnected else { return }
        // Only the host — or anyone in a collaborative room — may control playback.
        guard isHost || roomMode == JamRoomMode.collaborative else { return }
        // Suppress broadcasts triggered by applying a remote event.
        guard Date() > quietUntil else { return }

        let current = player.currentTrack
        let isPlaying = player.state == .playing
        let positionMs = currentPositionMs()
        let now = Date()

        if let current {
            let trackId = current.id.isEmpty ? current.title : current.id
            if trackId != lastBroadcastTrackId {
                lastBroadcastTrackId = trackId
                lastBroadcastIsPlaying = isPlaying
                lastBroadcastPositionMs = positionMs
                lastPolledPositionMs = positionMs
                lastPollTime = now
                quietUntil = now.addingTimeInterval(1.0)
                await broadcastPlaybackAction(.init(
                    action: JamPlaybackAction.changeTrack,
                    track: TrackInfoPayload(track: current),
                    positionMs: positionMs,
                    clientTimeMs: nowMs(),
                    isPlaying: isPlaying
                ))
                return
            }
            if isPlaying != lastBroadcastIsPlaying {
                lastBroadcastIsPlaying = isPlaying
                lastBroadcastPositionMs = positionMs
                lastPolledPositionMs = positionMs
                lastPollTime = now
                quietUntil = now.addingTimeInterval(0.8)
                if isPlaying {
                    await broadcastPlaybackAction(.init(
                        action: JamPlaybackAction.play,
                        positionMs: positionMs,
                        clientTimeMs: nowMs(),
                        isPlaying: true
                    ))
                } else {
                    await broadcastPlaybackAction(.init(
                        action: JamPlaybackAction.pause,
                        positionMs: positionMs,
                        clientTimeMs: nowMs(),
                        isPlaying: false
                    ))
                }
                return
            }
            // Seek detection: the position jumped further than the elapsed
            // poll interval allows (a jump over 2 s is a seek, not drift).
            let expected = lastPolledPositionMs + Int64(now.timeIntervalSince(lastPollTime) * 1_000)
            if isPlaying, abs(positionMs - expected) > Self.driftSeekThresholdMs {
                lastBroadcastPositionMs = positionMs
                quietUntil = now.addingTimeInterval(0.8)
                await broadcastPlaybackAction(.init(
                    action: JamPlaybackAction.seek,
                    positionMs: positionMs,
                    clientTimeMs: nowMs()
                ))
            }
        } else if isPlaying != lastBroadcastIsPlaying {
            lastBroadcastIsPlaying = isPlaying
            quietUntil = now.addingTimeInterval(0.8)
            if isPlaying {
                await broadcastPlaybackAction(.init(
                    action: JamPlaybackAction.play,
                    positionMs: positionMs,
                    clientTimeMs: nowMs(),
                    isPlaying: true
                ))
            } else {
                await broadcastPlaybackAction(.init(
                    action: JamPlaybackAction.pause,
                    positionMs: positionMs,
                    clientTimeMs: nowMs(),
                    isPlaying: false
                ))
            }
        }

        lastPolledPositionMs = positionMs
        lastPollTime = now

        // Host only: share the upcoming queue with the room (read-only).
        if isHost {
            let upcoming = Array(player.queue.dropFirst(player.queueIndex + 1).prefix(5))
                .map { TrackInfoPayload(track: $0.track) }
            let ids = upcoming.map(\.id)
            if ids != lastPublishedQueueIds {
                lastPublishedQueueIds = ids
                await publishQueue(upcoming)
            }
        }
    }

    // MARK: - Live station enforcement

    private func startLiveEnforcement() {
        liveEnforcementTask?.cancel()
        liveEnforcementTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                await self.enforceLive()
            }
        }
    }

    /// Live-station listeners cannot pause, seek or change the song: whatever
    /// the local player does on its own is undone and it rejoins the live
    /// position.
    private func enforceLive() async {
        guard isStationRadio, !isHost, let live = liveTrack, room != nil else { return }
        guard Date() > quietUntil else { return }
        let expected = livePositionMs + (liveIsPlaying ? Int64(Date().timeIntervalSince(liveAt) * 1_000) : 0)
        if player.currentTrack?.id != live.id {
            await applyTrackChange(live, positionMs: expected, isPlaying: liveIsPlaying)
            return
        }
        if liveIsPlaying, player.state != .playing {
            quietUntil = Date().addingTimeInterval(0.8)
            player.togglePlayPause()
        } else if !liveIsPlaying, player.state == .playing {
            quietUntil = Date().addingTimeInterval(0.8)
            player.togglePlayPause()
        }
        if abs(currentPositionMs() - expected) > Self.liveDriftThresholdMs {
            quietUntil = Date().addingTimeInterval(0.8)
            player.seek(to: Double(expected) / 1_000)
        }
    }

    // MARK: - Helpers

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private func currentPositionMs() -> Int64 {
        Int64(player.positionSeconds * 1_000)
    }
}
