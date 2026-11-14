import CryptoKit
import Foundation

// MARK: - Last.fm scrobbling
//
// Mirrors the Android app's `ScrobbleRepository` + `LastFmSigner`:
// authenticated writes go to `https://ws.audioscrobbler.com/2.0/` as a
// form-encoded POST with `method=track.scrobble`. The signature is MD5 over
// the alphabetically sorted params (excluding `format`, `callback` and
// `api_sig`), concatenated as key+value with no separator, plus the API
// secret — see last.fm/api/authspec.
//
// Auth: the API key + API secret come from Settings (the user creates them
// at last.fm/api), and the session key (`sk`) is obtained once via the
// desktop auth flow (`auth.getToken` -> user authorises -> `auth.getSession`)
// and stored in Settings. Scrobbling without a session key is a no-op —
// Last.fm has no anonymous scrobble endpoint.
//
// Reliability, per the Android contract: signed writes are serialised and
// spaced ≥700 ms apart; a rate-limit (HTTP 429 or error 29) or network
// failure queues the scrobble (max 200, persisted in UserDefaults) and it is
// retried on the next write instead of being dropped.

/// Only @MainActor callers (Player, StatsView); unchecked conformance is sound.
final class LastFmService: @unchecked Sendable {
    static let shared = LastFmService()

    private static let baseURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private static let writeSpacing: TimeInterval = 0.7
    private static let maxOfflineQueue = 200
    private static let queueDefaultsKey = "lastFmOfflineScrobbles"

    private let settings: SettingsStore
    private var lastWriteAt: Date?
    private var offlineQueue: [PendingScrobble]

    /// True when an API key is set in Settings. Scrobbling additionally
    /// needs the API secret and a session key; when those are missing the
    /// call is a silent no-op.
    var isConfigured: Bool {
        !settings.lastFmApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(settings: SettingsStore = .shared) {
        self.settings = settings
        if let data = UserDefaults.standard.data(forKey: Self.queueDefaultsKey),
           let decoded = try? JSONDecoder().decode([PendingScrobble].self, from: data) {
            self.offlineQueue = decoded
        } else {
            self.offlineQueue = []
        }
    }

    /// Scrobbles the track. The Player calls this at the halfway point of a
    /// track. The timestamp is the moment the track started playing (now
    /// minus half its duration when known). Failures are queued, never thrown.
    func scrobble(track: Track) async {
        let artist = track.artistNames
        guard !artist.isEmpty, !track.title.isEmpty else { return }
        let startedAt: TimeInterval
        if let duration = track.durationSeconds, duration > 0 {
            startedAt = Date().timeIntervalSince1970 - Double(duration) / 2
        } else {
            startedAt = Date().timeIntervalSince1970
        }
        let pending = PendingScrobble(
            artist: artist,
            track: track.title,
            album: track.album?.title,
            timestampSec: Int64(startedAt)
        )
        await flushPending()
        let result = await signedScrobble(pending)
        if result == .retryable {
            enqueue(pending)
        }
    }

    // MARK: - Private

    private struct PendingScrobble: Codable {
        var artist: String
        var track: String
        var album: String?
        var timestampSec: Int64
    }

    private enum ScrobbleOutcome {
        case success
        case permanentFailure
        case retryable
    }

    private func enqueue(_ pending: PendingScrobble) {
        offlineQueue.append(pending)
        while offlineQueue.count > Self.maxOfflineQueue {
            offlineQueue.removeFirst()
        }
        persistQueue()
    }

    private func persistQueue() {
        if let data = try? JSONEncoder().encode(offlineQueue) {
            UserDefaults.standard.set(data, forKey: Self.queueDefaultsKey)
        }
    }

    private func flushPending() async {
        guard !offlineQueue.isEmpty else { return }
        while !offlineQueue.isEmpty {
            let pending = offlineQueue[0]
            switch await signedScrobble(pending) {
            case .success:
                offlineQueue.removeFirst()
                persistQueue()
            case .permanentFailure, .retryable:
                return
            }
        }
    }

    private func signedScrobble(_ pending: PendingScrobble) async -> ScrobbleOutcome {
        let apiKey = Self.normalizeKey(settings.lastFmApiKey)
        let apiSecret = Self.normalizeKey(settings.lastFmApiSecret)
        guard !apiKey.isEmpty, !apiSecret.isEmpty else { return .permanentFailure }
        guard let sessionKey = settings.lastFmSessionKey, !sessionKey.isEmpty else {
            return .permanentFailure
        }

        // Keep signed writes spaced out; Last.fm is stricter about
        // authenticated write endpoints than reads.
        if let lastWriteAt, Date().timeIntervalSince(lastWriteAt) < Self.writeSpacing {
            let wait = Self.writeSpacing - Date().timeIntervalSince(lastWriteAt)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }

        var params: [String: String] = [
            "method": "track.scrobble",
            "artist": pending.artist,
            "track": pending.track,
            "timestamp": String(pending.timestampSec),
            "api_key": apiKey,
            "sk": sessionKey,
        ]
        if let album = pending.album, !album.isEmpty {
            params["album"] = album
        }
        params["api_sig"] = Self.sign(params: params, secret: apiSecret)
        params["format"] = "json"

        var request = URLRequest(url: Self.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params
            .map { key, value in
                "\(Self.formEncode(key))=\(Self.formEncode(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            lastWriteAt = Date()
            if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                return .retryable
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .retryable }
            if let errorCode = json["error"] as? Int {
                // 29 is Last.fm's rate-limit error.
                return errorCode == 29 ? .retryable : .permanentFailure
            }
            return .success
        } catch {
            return .retryable
        }
    }

    /// Last.fm signing: sort keys alphabetically, concatenate key+value with
    /// no separator, append the secret, MD5-hex the UTF-8 bytes. `format`,
    /// `callback` and `api_sig` are excluded from the signature.
    static func sign(params: [String: String], secret: String) -> String {
        let base = params
            .filter { !["format", "callback", "api_sig"].contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined() + secret
        let digest = Insecure.MD5.hash(data: Data(base.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// API keys/secrets are 32-char lowercase hex; stray whitespace or
    /// invisible unicode pasted from a browser is silently cleaned up.
    static func normalizeKey(_ raw: String) -> String {
        let whitespace = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{00A0}\u{200B}\u{200C}\u{200D}\u{FEFF}"))
        let stripped = raw.components(separatedBy: whitespace).joined()
        return stripped.filter { $0.isHexDigit }.lowercased()
    }

    /// Form encoding with a strict character set: `urlQueryAllowed` lets
    /// `&` and `=` through, which would split a value into extra params.
    private static let formAllowedCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowedCharacters) ?? value
    }
}
