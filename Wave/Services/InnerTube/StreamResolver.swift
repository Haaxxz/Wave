import Foundation

// MARK: - Stream resolution
//
// Resolves a video id to playable audio URLs through the InnerTube
// `player` endpoint, mirroring Android `resolveDirectClientStream` in
// `InnerTubeMusicApiStreamResolver.kt`: WEB_REMIX client, signature
// timestamp from the current player script, poToken when one can be
// minted, ciphered formats deciphered, throttling parameters
// deobfuscated, and the GVS `pot=` token appended to googlevideo URLs.
//
// Only WEB_REMIX (never an IOS-family client) is used for audio URLs:
// there is no mintable iOS GVS token, and those URLs fail without one.

enum StreamError: Error, Sendable {
    case noClient
    case unplayable(String)
    case noAudioFormats
}

@MainActor
final class StreamResolver {
    private weak var client: InnerTubeClient?

    init(client: InnerTubeClient) {
        self.client = client
    }

    /// All usable audio-only formats for a video, best first. The Player
    /// picks from this list for the current network and quality setting.
    func resolve(videoId: String) async throws -> StreamInfo {
        guard let client else { throw StreamError.noClient }
        let config = await client.webConfig()
        let visitorData = await client.currentVisitorData()
        let isLoggedIn = YouTubeSession.shared.isLoggedIn

        let signatureTimestamp = await SignatureDecipher.shared.signatureTimestamp(videoId: videoId)
        let playerPoToken = try? await PoTokenGenerator.shared.token(forVideoId: videoId)

        let context = client.makeContext(
            clientName: "WEB_REMIX",
            clientVersion: config.clientVersion,
            visitorData: visitorData,
            authenticated: isLoggedIn
        )
        let body = Self.playerBody(
            videoId: videoId,
            context: context,
            signatureTimestamp: signatureTimestamp,
            playerPoToken: playerPoToken
        )
        let root = try await client.postJSON(
            endpoint: "player",
            body: body,
            clientName: "WEB_REMIX",
            clientVersion: config.clientVersion,
            authenticated: isLoggedIn
        )
        let parsed = InnerTubeParsing.parseStreamFormats(in: root)
        if parsed.playabilityStatus != "OK", parsed.formats.isEmpty {
            throw StreamError.unplayable(parsed.reason ?? parsed.playabilityStatus ?? "Unknown player error")
        }

        // Resolve each audio format to a playable URL.
        struct ResolvedFormat {
            let raw: InnerTubeParsing.RawAudioFormat
            let url: URL
        }
        var resolved: [ResolvedFormat] = []
        for raw in parsed.formats {
            guard raw.mimeType.lowercased().hasPrefix("audio/") else { continue }
            var urlString: String?
            if let direct = raw.url {
                urlString = direct
            } else if let cipher = raw.cipher {
                urlString = try? await SignatureDecipher.shared.decipher(videoId: videoId, signatureCipher: cipher)
            }
            guard var urlString else { continue }
            urlString = await SignatureDecipher.shared.deobfuscateThrottlingParameter(videoId: videoId, url: urlString)
            if let sessionToken = try? await PoTokenGenerator.shared.token(), !sessionToken.isEmpty {
                urlString = InnerTubeParsing.appendingPoToken(to: urlString, token: sessionToken)
            }
            guard let url = URL(string: urlString) else { continue }
            resolved.append(ResolvedFormat(raw: raw, url: url))
        }

        let maxBitrateBps = SettingsStore.shared.audioQuality.targetBitrateKbps * 1_000
        var candidates = resolved.filter { item in
            InnerTubeParsing.isCompatibleAudio(mimeType: item.raw.mimeType)
                && item.raw.bitrate >= 1 && item.raw.bitrate <= maxBitrateBps
        }
        if candidates.isEmpty {
            // A response whose bitrates are all missing or above the cap
            // still has playable audio; do not fail the song over it.
            candidates = resolved.filter { InnerTubeParsing.isCompatibleAudio(mimeType: $0.raw.mimeType) }
        }
        guard !candidates.isEmpty else { throw StreamError.noAudioFormats }

        // Same ordering as Android: non-DRC first, non-adaptive first,
        // Opus (webm) before AAC, then highest bitrate.
        candidates.sort { lhs, rhs in
            if lhs.raw.isDrc != rhs.raw.isDrc { return !lhs.raw.isDrc }
            if lhs.raw.isAdaptive != rhs.raw.isAdaptive { return !lhs.raw.isAdaptive }
            let lhsOpus = lhs.raw.mimeType.lowercased().contains("webm")
            let rhsOpus = rhs.raw.mimeType.lowercased().contains("webm")
            if lhsOpus != rhsOpus { return lhsOpus }
            return lhs.raw.bitrate > rhs.raw.bitrate
        }

        let formats = candidates.map { item in
            AudioFormat(
                url: item.url,
                itag: item.raw.itag,
                mimeType: item.raw.mimeType.components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces) ?? item.raw.mimeType,
                bitrate: item.raw.bitrate,
                contentLength: item.raw.contentLength,
                isAdaptive: item.raw.isAdaptive
            )
        }
        return StreamInfo(
            videoId: videoId,
            formats: formats,
            durationSeconds: parsed.durationSeconds,
            isLive: parsed.isLive
        )
    }

    /// The best format in a resolved `StreamInfo` for the given bitrate
    /// cap (nil means the list order, already best first).
    static func bestFormat(in info: StreamInfo, maxBitrateBps: Int? = nil) -> AudioFormat? {
        guard let cap = maxBitrateBps else { return info.formats.first }
        return info.formats.first(where: { $0.bitrate >= 1 && $0.bitrate <= cap })
            ?? info.formats.first
    }

    /// The `player` request body. Player integrity is a top-level field,
    /// separate from the client context. Mirrors Android
    /// `playbackPlayerBody`.
    static func playerBody(
        videoId: String,
        context: [String: Any],
        signatureTimestamp: Int?,
        playerPoToken: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "context": context,
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        if let playerPoToken, !playerPoToken.isEmpty {
            body["serviceIntegrityDimensions"] = ["poToken": playerPoToken]
        }
        // Only a timestamp extracted from the current player is valid;
        // omit it on extraction failure.
        if let signatureTimestamp {
            body["playbackContext"] = [
                "contentPlaybackContext": ["signatureTimestamp": signatureTimestamp]
            ]
        }
        return body
    }
}
