import XCTest

@testable import Wave

// MARK: - Jam protocol tests
//
// Round-trips the exact JSON the server speaks (see
// `Wave/Services/Social/JamClient.swift`, ported from the Android app's
// `data/jam/JamProtocol.kt`). No network is involved.

final class JamProtocolTests: XCTestCase {
    func testCreateRoomEnvelopeEncodesExactKeys() throws {
        let envelope = JamEnvelope(
            type: JamMessageType.createRoom,
            payload: CreateRoomRequest(name: "Friday Jam")
        )
        let data = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "create_room")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["name"] as? String, "Friday Jam")
        XCTAssertEqual(payload["room_mode"] as? String, "collaborative")
    }

    func testJoinRoomEnvelopeEncodesExactKeys() throws {
        let envelope = JamEnvelope(
            type: JamMessageType.joinRoom,
            payload: JoinRoomRequest(roomCode: "ABC123", name: "Shihas")
        )
        let data = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "join_room")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["room_code"] as? String, "ABC123")
        XCTAssertEqual(payload["name"] as? String, "Shihas")
    }

    func testPlaybackActionRoundTripWithTrack() throws {
        let track = TrackInfoPayload(
            id: "dQw4w9WgXcQ",
            title: "Test Song",
            artist: "Test Artist",
            album: "Test Album",
            artworkUrl: "https://example.com/art.jpg",
            durationMs: 214_000
        )
        let action = PlaybackActionPayload(
            action: JamPlaybackAction.changeTrack,
            fromUserId: "user-1",
            track: track,
            positionMs: 42_000,
            clientTimeMs: 1_700_000_000_000,
            serverTimeMs: 1_700_000_000_100,
            isPlaying: true,
            revision: 7
        )
        let envelope = JamEnvelope(type: JamMessageType.playbackAction, payload: action)
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(JamEnvelope<PlaybackActionPayload>.self, from: data)
        XCTAssertEqual(decoded.type, "playback_action")
        let payload = try XCTUnwrap(decoded.payload)
        XCTAssertEqual(payload.action, "change_track")
        XCTAssertEqual(payload.fromUserId, "user-1")
        XCTAssertEqual(payload.positionMs, 42_000)
        XCTAssertEqual(payload.clientTimeMs, 1_700_000_000_000)
        XCTAssertEqual(payload.serverTimeMs, 1_700_000_000_100)
        XCTAssertEqual(payload.isPlaying, true)
        XCTAssertEqual(payload.revision, 7)
        let decodedTrack = try XCTUnwrap(payload.track)
        XCTAssertEqual(decodedTrack.id, "dQw4w9WgXcQ")
        XCTAssertEqual(decodedTrack.title, "Test Song")
        XCTAssertEqual(decodedTrack.artist, "Test Artist")
        XCTAssertEqual(decodedTrack.album, "Test Album")
        XCTAssertEqual(decodedTrack.artworkUrl, "https://example.com/art.jpg")
        XCTAssertEqual(decodedTrack.durationMs, 214_000)
    }

    func testSyncStateDecodesExactKeys() throws {
        let json = """
        {
            "room_code": "XYZ789",
            "user_id": "user-2",
            "name": "Listener",
            "is_host": false,
            "host_id": "user-1",
            "cohost_id": "",
            "permanent": false,
            "room_name": "India",
            "radio": true,
            "station_auto": true,
            "room_mode": "collaborative",
            "playback": {
                "current_track": {
                    "id": "abc123",
                    "title": "Live Song",
                    "artist": "Live Artist",
                    "duration_ms": 180000
                },
                "position_ms": 65000,
                "server_time_ms": 1700000000100,
                "is_playing": true,
                "queue": [],
                "revision": 3
            },
            "participants": [
                {"user_id": "user-1", "name": "Host", "is_host": true, "is_cohost": false, "joined_at": 1700000000000},
                {"user_id": "user-2", "name": "Listener", "is_host": false, "is_cohost": false, "joined_at": 1700000001000}
            ],
            "chat_history": [
                {"id": "msg-1", "user_id": "user-1", "user_name": "Host", "is_host": true, "text": "hello", "timestamp": 1700000002000}
            ]
        }
        """
        let payload = try JSONDecoder().decode(SyncStatePayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.roomCode, "XYZ789")
        XCTAssertEqual(payload.userId, "user-2")
        XCTAssertEqual(payload.isHost, false)
        XCTAssertEqual(payload.hostId, "user-1")
        XCTAssertEqual(payload.roomName, "India")
        XCTAssertEqual(payload.radio, true)
        XCTAssertEqual(payload.stationAuto, true)
        XCTAssertEqual(payload.roomMode, "collaborative")
        XCTAssertEqual(payload.playback.positionMs, 65_000)
        XCTAssertEqual(payload.playback.serverTimeMs, 1_700_000_000_100)
        XCTAssertEqual(payload.playback.isPlaying, true)
        XCTAssertEqual(payload.playback.revision, 3)
        XCTAssertEqual(payload.playback.currentTrack?.title, "Live Song")
        XCTAssertEqual(payload.participants.count, 2)
        XCTAssertEqual(payload.participants[0].name, "Host")
        XCTAssertTrue(payload.participants[0].isHost)
        XCTAssertEqual(payload.chatHistory.count, 1)
        XCTAssertEqual(payload.chatHistory[0].text, "hello")
    }

    func testRoomCreatedDecodesExactKeys() throws {
        let json = """
        {"room_code": "NEW123", "user_id": "user-9", "name": "Host", "is_host": true, "room_mode": "host_only"}
        """
        let payload = try JSONDecoder().decode(RoomCreatedPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.roomCode, "NEW123")
        XCTAssertEqual(payload.userId, "user-9")
        XCTAssertEqual(payload.isHost, true)
        XCTAssertEqual(payload.roomMode, "host_only")
    }

    func testErrorPayloadDecodesExactKeys() throws {
        let json = """
        {"code": "rate_limited", "message": "Slow down", "retry_after_ms": 5000, "retry_at_ms": 1700000005000}
        """
        let payload = try JSONDecoder().decode(ErrorPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.code, "rate_limited")
        XCTAssertEqual(payload.message, "Slow down")
        XCTAssertEqual(payload.retryAfterMs, 5_000)
        XCTAssertEqual(payload.retryAtMs, 1_700_000_000_500)
    }

    func testTrackInfoPayloadFromTrackRoundTrip() {
        let track = Track(
            id: "vid-1",
            title: "Song",
            artists: [ArtistRef(id: "a1", name: "Singer")],
            album: AlbumRef(id: "al1", title: "Album"),
            durationSeconds: 200,
            thumbnails: [Thumbnail(url: URL(string: "https://example.com/cover.jpg"), width: 512, height: 512)]
        )
        let payload = TrackInfoPayload(track: track)
        XCTAssertEqual(payload.id, "vid-1")
        XCTAssertEqual(payload.title, "Song")
        XCTAssertEqual(payload.artist, "Singer")
        XCTAssertEqual(payload.album, "Album")
        XCTAssertEqual(payload.artworkUrl, "https://example.com/cover.jpg")
        XCTAssertEqual(payload.durationMs, 200_000)
        XCTAssertNil(payload.source)

        let restored = payload.toTrack()
        XCTAssertEqual(restored.id, "vid-1")
        XCTAssertEqual(restored.title, "Song")
        XCTAssertEqual(restored.artistNames, "Singer")
        XCTAssertEqual(restored.durationSeconds, 200)
    }

    func testParseJamCode() {
        XCTAssertEqual(parseJamCode("abc123"), "ABC123")
        XCTAssertEqual(parseJamCode("  xyz789  "), "XYZ789")
        XCTAssertEqual(parseJamCode("https://jam.clashgram.org/?code=def456"), "DEF456")
        XCTAssertEqual(parseJamCode("wave://jam?code=ghi789&foo=bar"), "GHI789")
        XCTAssertEqual(parseJamCode("https://jam.clashgram.org/?code=jkl012#section"), "JKL012")
        XCTAssertEqual(parseJamCode(""), "")
    }
}
