import Foundation
import WebKit

// MARK: - poToken (BotGuard)
//
// Headless BotGuard engine that mints valid YouTube Proof-of-Origin
// (`po_token`) values by running Google's JS challenge in a WKWebView.
// Swift port of the Android `BotGuardTokenGenerator` + `po_token.html`.
//
// Flow, exactly as on Android:
//   1. Load the bundled BotGuard client page in a headless WKWebView.
//   2. POST `https://www.youtube.com/api/jnn/v1/Create` with
//      `["O43z0dpjhgX20SCx4KAo"]` -> challenge `{program, globalName,
//      interpreterJavascript}`.
//   3. Run the challenge in the page (`runBotGuard`) -> BotGuard response.
//   4. POST `…/api/jnn/v1/GenerateIT` with `[key, botguardResponse]` ->
//      integrity token (base64) + lifetime.
//   5. Create the minter in the page (`createPoTokenMinter`), then mint
//      per-video tokens (`obtainPoToken`) and a session token.
// The jnn endpoints are a gRPC-web API keyed by the public WEB client
// key; without those headers Create answers with an error.
//
// Failures are typed and surfaced — a token is never faked. After three
// consecutive bootstrap failures minting pauses for 15 minutes and
// playback continues without a token (YouTube may reject some streams).

enum PoTokenError: Error, Sendable {
    case network
    case webViewUnavailable
    case createFailed(Int)
    case generateFailed(Int)
    case challengeFormat(String)
    case javaScriptError(String)
    case timeout
    case cooldownActive
    case engineNotReady
}

final class PoTokenGenerator: Sendable {
    static let shared = PoTokenGenerator()

    private static let createURL = "https://www.youtube.com/api/jnn/v1/Create"
    private static let generateITURL = "https://www.youtube.com/api/jnn/v1/GenerateIT"
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    private static let coldStartTimeoutSeconds = 10.0
    private static let warmTimeoutSeconds = 3.0
    private static let bootstrapFailureThreshold = 3
    private static let bootstrapCooldownSeconds: TimeInterval = 15 * 60
    private static let sessionTokenValiditySeconds: TimeInterval = 50 * 60
    private static let maxPlayerTokenCacheEntries = 200

    // MARK: - Visitor data (lock-guarded; readable off the main actor)

    private let lock = NSLock()
    // Lock-guarded on every access; the compiler cannot see the discipline.
    private nonisolated(unsafe) var _visitorData: String?

    /// The YouTube `visitorData` for this install. Mirrors the contract:
    /// the InnerTube client reads it from here.
    var visitorData: String? {
        lock.withLock { _visitorData }
    }

    private init() {
        _visitorData = UserDefaults.standard.string(forKey: "visitorData")
    }

    private func setVisitorData(_ value: String?) {
        lock.withLock { _visitorData = value }
        Task { @MainActor in SettingsStore.shared.visitorData = value }
    }

    /// Resolves visitor data: cached value, then the `visitor_id`
    /// endpoint, then the homepage scrape, then `sw.js_data`.
    func ensureVisitorData() async -> String? {
        if let visitor = visitorData, InnerTubeConstants.isValidVisitorData(visitor) {
            return visitor
        }
        if let visitor = try? await fetchVisitorId(),
           InnerTubeConstants.isValidVisitorData(visitor) {
            setVisitorData(visitor)
            return visitor
        }
        if let visitor = try? await scrapeVisitorData(),
           InnerTubeConstants.isValidVisitorData(visitor) {
            setVisitorData(visitor)
            return visitor
        }
        return visitorData
    }

    private func fetchVisitorId() async throws -> String? {
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB_REMIX",
                    "clientVersion": InnerTubeConstants.fallbackClientVersion,
                    "hl": "en",
                    "gl": "US",
                ]
            ]
        ]
        guard let url = URL(string: "\(InnerTubeConstants.musicAPI)/visitor_id?key=\(InnerTubeConstants.fallbackAPIKey)&prettyPrint=false") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(InnerTubeConstants.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(InnerTubeConstants.musicOrigin, forHTTPHeaderField: "Origin")
        request.setValue(InnerTubeConstants.musicOrigin + "/", forHTTPHeaderField: "Referer")
        request.setValue(InnerTubeConstants.consentCookie, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        return try JSONValue(data: data).object("responseContext")?.string("visitorData")
    }

    private func scrapeVisitorData() async throws -> String? {
        func fetch(_ urlString: String) async -> String? {
            guard let url = URL(string: urlString) else { return nil }
            var request = URLRequest(url: url)
            request.setValue(InnerTubeConstants.webUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(InnerTubeConstants.consentCookie, forHTTPHeaderField: "Cookie")
            request.timeoutInterval = 15
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text
        }
        if let html = await fetch(InnerTubeConstants.musicOrigin + "/") {
            if let visitor = findConfig(html, key: "VISITOR_DATA") ?? findConfig(html, key: "EOM_VISITOR_DATA") {
                return visitor
            }
        }
        if let jsData = await fetch(InnerTubeConstants.musicOrigin + "/sw.js_data") {
            // sw.js_data is JSON, so the same "KEY": "value" search as
            // the homepage covers it (plain and escaped forms).
            if let visitor = findConfig(jsData, key: "visitorData") ?? findConfig(jsData, key: "VISITOR_DATA") {
                return visitor
            }
        }
        return nil
    }

    private func findConfig(_ html: String, key: String) -> String? {
        let patterns = [
            "\"" + key + "\"\\s*:\\s*\"([^\"]+)\"",
            "\\\\\"" + key + "\\\\\"\\\\s*:\\\\s*\\\\\"([^\\\\\"]+)\\\\\"",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html) else {
                continue
            }
            let value = String(html[range])
                .replacingOccurrences(of: "\\u003d", with: "=")
                .replacingOccurrences(of: "\\x3d", with: "=")
                .replacingOccurrences(of: "\\/", with: "/")
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Engine state (main actor; the WKWebView lives there)

    @MainActor private var engine: BotGuardEngine?
    @MainActor private var engineSessionId: String?
    @MainActor private var cachedSessionToken: (token: String, expiresAt: Date)?
    @MainActor private var playerTokenCache: [String: (token: String, expiresAt: Date)] = [:]
    @MainActor private var consecutiveFailures = 0
    @MainActor private var cooldownUntil: Date?

    /// The session poToken, used as the GVS `pot=` parameter on stream
    /// URLs. Minted once per engine bootstrap and cached until expiry.
    func token() async throws -> String {
        try await self.sessionToken()
    }

    /// The per-video player poToken for the `player` request's
    /// `serviceIntegrityDimensions`.
    func token(forVideoId videoId: String) async throws -> String {
        try await self.playerToken(videoId: videoId)
    }

    @MainActor
    private func sessionToken() async throws -> String {
        if let cached = cachedSessionToken, cached.expiresAt > Date() {
            return cached.token
        }
        _ = try await ensureEngine()
        guard let cached = cachedSessionToken, cached.expiresAt > Date() else {
            throw PoTokenError.engineNotReady
        }
        return cached.token
    }

    @MainActor
    private func playerToken(videoId: String) async throws -> String {
        if let cached = playerTokenCache[videoId], cached.expiresAt > Date() {
            return cached.token
        }
        let engine = try await ensureEngine()
        let token = try await Self.withTimeout(seconds: Self.warmTimeoutSeconds) {
            try await engine.mint(identifier: videoId)
        }
        playerTokenCache[videoId] = (token: token, expiresAt: Date().addingTimeInterval(Self.sessionTokenValiditySeconds))
        if playerTokenCache.count > Self.maxPlayerTokenCacheEntries,
           let first = playerTokenCache.keys.first {
            playerTokenCache.removeValue(forKey: first)
        }
        return token
    }

    @MainActor
    private func ensureEngine() async throws -> BotGuardEngine {
        let sessionId = visitorData ?? "lastwave_session"
        if let engine, engineSessionId == sessionId, !engine.isExpired,
           let cached = cachedSessionToken, cached.expiresAt > Date() {
            return engine
        }
        if let cooldownUntil, Date() < cooldownUntil {
            throw PoTokenError.cooldownActive
        }
        engine?.close()
        engine = nil
        engineSessionId = nil
        cachedSessionToken = nil
        do {
            let newEngine = try await Self.withTimeout(seconds: Self.coldStartTimeoutSeconds) {
                try await self.bootstrapEngine(sessionId: sessionId)
            }
            engine = newEngine
            engineSessionId = sessionId
            consecutiveFailures = 0
            cooldownUntil = nil
            return newEngine
        } catch {
            recordFailure(error: error)
            throw error
        }
    }

    @MainActor
    private func bootstrapEngine(sessionId: String) async throws -> BotGuardEngine {
        let newEngine = BotGuardEngine(owner: self)
        do {
            try await newEngine.waitForPageLoaded()
            let challengeJSON = try await createChallenge()
            let botguardResponse = try await newEngine.runChallenge(challengeJSON)
            let (tokenU8JS, lifetimeSeconds) = try await generateIntegrityToken(botguardResponse)
            try await newEngine.createMinter(tokenU8JS: tokenU8JS)
            let sessionToken = try await newEngine.mint(identifier: sessionId)
            newEngine.expiresAt = Date().addingTimeInterval(TimeInterval(max(lifetimeSeconds - 300, 60)))
            cachedSessionToken = (token: sessionToken, expiresAt: newEngine.expiresAt)
            return newEngine
        } catch {
            newEngine.close()
            throw error
        }
    }

    @MainActor
    private func recordFailure(error: Error) {
        consecutiveFailures += 1
        var refused = false
        switch error as? PoTokenError {
        case .challengeFormat:
            refused = true
        case .createFailed(let code), .generateFailed(let code):
            refused = (400...499).contains(code)
        default:
            break
        }
        if refused || consecutiveFailures >= Self.bootstrapFailureThreshold {
            cooldownUntil = Date().addingTimeInterval(Self.bootstrapCooldownSeconds)
        }
    }

    // MARK: - BotGuard HTTP API

    @MainActor
    private func createChallenge() async throws -> String {
        let raw = try await callBotGuardAPI(
            url: Self.createURL,
            body: "[ \"\(Self.requestKey)\" ]",
            endpoint: "Create"
        )
        return try Self.parseCreateChallenge(raw)
    }

    @MainActor
    private func generateIntegrityToken(_ botguardResponse: String) async throws -> (tokenU8JS: String, lifetimeSeconds: Int) {
        let bodyData = try JSONSerialization.data(withJSONObject: [Self.requestKey, botguardResponse])
        guard let body = String(data: bodyData, encoding: .utf8) else {
            throw PoTokenError.challengeFormat("Could not encode GenerateIT body")
        }
        let raw = try await callBotGuardAPI(url: Self.generateITURL, body: body, endpoint: "GenerateIT")
        return try Self.parseIntegrityToken(raw)
    }

    @MainActor
    private func callBotGuardAPI(url: String, body: String, endpoint: String) async throws -> String {
        guard let requestURL = URL(string: url) else {
            throw PoTokenError.challengeFormat("Bad BotGuard URL")
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(InnerTubeConstants.jnnAPIKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
        request.setValue(InnerTubeConstants.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PoTokenError.network }
        guard http.statusCode == 200 else {
            if endpoint == "Create" { throw PoTokenError.createFailed(http.statusCode) }
            throw PoTokenError.generateFailed(http.statusCode)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Challenge parsing (port of Android ChallengeParser.kt)

    /// Parses a `Create` response into the challenge JSON the page's
    /// `runBotGuard` expects: `{program, globalName, interpreterJavascript}`.
    static func parseCreateChallenge(_ rawResponse: String) throws -> String {
        guard let root = parseJSONElement(rawResponse) else {
            throw PoTokenError.challengeFormat("Create response was not JSON")
        }
        let challenge: [JSONValue]?
        if case .array(let outer) = root {
            challenge = extractLegacyChallenge(outer) ?? findChallengeArray(root)
        } else if case .object = root {
            challenge = findChallengeArray(root)
        } else {
            challenge = nil
        }
        guard let challenge else {
            throw PoTokenError.challengeFormat("Create response had no challenge array with program/globalName slots [4]/[5]")
        }
        return try buildChallengePayload(challenge)
    }

    /// Parses a `GenerateIT` response into the integrity token as a JS
    /// `Uint8Array` literal plus its lifetime in seconds.
    static func parseIntegrityToken(_ rawResponse: String) throws -> (tokenU8JS: String, lifetimeSeconds: Int) {
        guard let root = parseJSONElement(rawResponse) else {
            throw PoTokenError.challengeFormat("GenerateIT response was not JSON")
        }
        let pair: (String, Int)?
        if case .array(let array) = root {
            pair = readTokenPair(array)
        } else if case .object = root {
            pair = findLegacyTokenArray(root).flatMap(readTokenPair) ?? findIntegrityFields(root)
        } else {
            pair = nil
        }
        guard let pair else {
            throw PoTokenError.challengeFormat("GenerateIT response had no [token, lifetime] pair")
        }
        return pair
    }

    /// Converts a plain-string identifier to a JavaScript
    /// `Uint8Array(...)` literal.
    static func stringToJsUint8Array(_ identifier: String) -> String {
        let bytes = Array(identifier.utf8)
        return "new Uint8Array([\(bytes.map(String.init).joined(separator: ","))])"
    }

    /// Converts a comma-separated byte list (output of
    /// `Uint8Array.toString()` in JS) to URL-safe Base64 without padding.
    static func commaSeparatedBytesToBase64URL(_ csv: String) -> String? {
        let parts = csv.split(separator: ",")
        guard !parts.isEmpty else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            bytes.append(value)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func parseJSONElement(_ raw: String) -> JSONValue? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONValue(data: data)
    }

    private static func extractLegacyChallenge(_ outer: [JSONValue]) -> [JSONValue]? {
        if outer.count > 1, case .string(let scrambled) = outer[1] {
            guard let decoded = descramble(scrambled),
                  let parsed = parseJSONElement(decoded),
                  case .array(let array) = parsed else { return nil }
            return array
        }
        if case .array(let array) = outer.first { return array }
        return nil
    }

    private static func findChallengeArray(_ root: JSONValue) -> [JSONValue]? {
        for element in walkJSON(root) {
            if case .array(let array) = element, isChallengeShaped(array) { return array }
        }
        for element in walkJSON(root) {
            if case .string(let text) = element, text.count >= 16,
               let decoded = descramble(text),
               let parsed = parseJSONElement(decoded),
               case .array(let array) = parsed, isChallengeShaped(array) {
                return array
            }
        }
        return nil
    }

    private static func isChallengeShaped(_ array: [JSONValue]) -> Bool {
        guard array.count >= 6 else { return false }
        if case .string = array[4], case .string = array[5] { return true }
        return false
    }

    private static func buildChallengePayload(_ challenge: [JSONValue]) throws -> String {
        guard challenge.count >= 6 else {
            throw PoTokenError.challengeFormat("Create challenge array has size \(challenge.count); need program/globalName string slots [4]/[5]")
        }
        guard case .string(let program) = challenge[4] else {
            throw PoTokenError.challengeFormat("Create challenge slot [4] is not the program string")
        }
        guard case .string(let globalName) = challenge[5] else {
            throw PoTokenError.challengeFormat("Create challenge slot [5] is not the global-name string")
        }
        let interpreterJs = firstStringElement(challenge.count > 1 ? challenge[1] : nil)
        let interpreterUrl = firstStringElement(challenge.count > 2 ? challenge[2] : nil)
        let payload: [String: Any] = [
            "program": program,
            "globalName": globalName,
            "interpreterJavascript": [
                "privateDoNotAccessOrElseSafeScriptWrappedValue": interpreterJs ?? NSNull() as Any,
                "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue": interpreterUrl ?? NSNull() as Any,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            throw PoTokenError.challengeFormat("Could not encode challenge payload")
        }
        return text
    }

    private static func firstStringElement(_ element: JSONValue?) -> String? {
        guard let element else { return nil }
        if case .string(let text) = element { return text }
        if case .array(let items) = element {
            for item in items {
                if case .string(let text) = item { return text }
            }
        }
        return nil
    }

    private static func readTokenPair(_ array: [JSONValue]) -> (String, Int)? {
        guard array.count >= 2,
              case .string(let token) = array[0],
              let lifetime = array[1].asInt,
              let tokenU8 = base64ToJsUint8Array(token) else {
            return nil
        }
        return (tokenU8, lifetime)
    }

    private static func findLegacyTokenArray(_ root: JSONValue) -> [JSONValue]? {
        for element in walkJSON(root) {
            guard case .array(let array) = element, array.count >= 2,
                  case .string = array[0],
                  array[1].asInt != nil else {
                continue
            }
            return array
        }
        return nil
    }

    private static func findIntegrityFields(_ root: JSONValue) -> (String, Int)? {
        var bestToken: (String, Int)?
        var bestLifetime: (Int, Int)?
        for (key, value) in walkEntries(root) {
            if case .string(let text) = value, isTokenLike(text) {
                var score = min(text.count, 1_000)
                if ["token", "integrity"].contains(where: { key.localizedCaseInsensitiveContains($0) }) {
                    score += 10_000
                }
                if bestToken == nil || score > bestToken!.1 {
                    bestToken = (text, score)
                }
            } else if let number = value.asInt, (60...86_400).contains(number) {
                var score = 0
                if ["lifetime", "expires", "ttl", "expiry"].contains(where: { key.localizedCaseInsensitiveContains($0) }) {
                    score += 100
                }
                if bestLifetime == nil || score > bestLifetime!.1 {
                    bestLifetime = (number, score)
                }
            }
        }
        guard let token = bestToken?.0, let lifetime = bestLifetime?.0,
              let tokenU8 = base64ToJsUint8Array(token) else {
            return nil
        }
        return (tokenU8, lifetime)
    }

    private static func isTokenLike(_ text: String) -> Bool {
        if text.count < 32 { return false }
        if text.localizedCaseInsensitiveContains("http") || text.contains("www.") { return false }
        if text.contains(where: { $0.isWhitespace }) { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || "+/=-_.".contains($0) }
    }

    private static func walkJSON(_ root: JSONValue, budget: Int = 20_000) -> [JSONValue] {
        var result: [JSONValue] = []
        var stack: [JSONValue] = [root]
        var remaining = budget
        while let current = stack.popLast(), remaining > 0 {
            remaining -= 1
            result.append(current)
            switch current {
            case .object(let dict):
                for value in dict.values { stack.append(value) }
            case .array(let items):
                for value in items { stack.append(value) }
            default:
                break
            }
        }
        return result
    }

    private static func walkEntries(_ root: JSONValue, budget: Int = 20_000) -> [(String, JSONValue)] {
        var result: [(String, JSONValue)] = []
        var stack: [(String, JSONValue)] = []
        switch root {
        case .object(let dict):
            for (key, value) in dict { stack.append((key, value)) }
        case .array(let items):
            for (index, value) in items.enumerated() { stack.append(("#\(index)", value)) }
        default:
            break
        }
        var remaining = budget
        while let (key, current) = stack.popLast(), remaining > 0 {
            remaining -= 1
            result.append((key, current))
            switch current {
            case .object(let dict):
                for (childKey, value) in dict { stack.append((childKey, value)) }
            case .array(let items):
                for (index, value) in items.enumerated() { stack.append(("\(key)#\(index)", value)) }
            default:
                break
            }
        }
        return result
    }

    private static func descramble(_ base64Payload: String) -> String? {
        guard let data = base64ToData(base64Payload) else { return nil }
        let bytes = data.map { $0 &+ 97 }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func base64ToJsUint8Array(_ base64: String) -> String? {
        guard let data = base64ToData(base64) else { return nil }
        return "new Uint8Array([\(data.map { String($0) }.joined(separator: ","))])"
    }

    private static func base64ToData(_ base64: String) -> Data? {
        let normalized = base64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: padded, options: .ignoreUnknownCharacters)
    }

    // MARK: - Timeout helper

    @MainActor
    static func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PoTokenError.timeout
            }
            guard let result = try await group.next() else { throw PoTokenError.timeout }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Bundled BotGuard client page
    //
    // The BotGuard client from the Android app's `assets/po_token.html`,
    // with the Android `@JavascriptInterface` bridge replaced by a
    // `window.webkit.messageHandlers.BotGuardBridge` shim. Every snippet
    // the engine evaluates is wrapped in an IIFE that returns undefined:
    // WKWebView awaits returned promises, which would swallow the bridge
    // callbacks that resolve the continuations.

    static let botGuardHTML = """
    <!DOCTYPE html>
    <html lang="en"><head><title></title><script>
    var BotGuardBridge = {
      post: function(obj) { window.webkit.messageHandlers.BotGuardBridge.postMessage(JSON.stringify(obj)); },
      onPageLoaded: function() { this.post({event: "onPageLoaded"}); },
      onBotGuardReady: function(r) { this.post({event: "onBotGuardReady", response: r}); },
      onMinterReady: function() { this.post({event: "onMinterReady"}); },
      onMintOk: function(id, csv) { this.post({event: "onMintOk", id: id, csv: csv}); },
      onMintErr: function(id, err) { this.post({event: "onMintErr", id: id, error: String(err)}); },
      onFatalError: function(e) { this.post({event: "onFatalError", error: String(e)}); }
    };
    var bgVmFunctions = null;
    var bgVm = null;
    var bgProgram = null;
    var poTokenMinter = null;

    function loadBotGuard(challengeData) {
      bgVm = window[challengeData.globalName];
      bgProgram = challengeData.program;
      bgVmFunctions = null;

      if (!bgVm)
        throw new Error('[BotGuardClient]: VM not found in the global object');

      if (!bgVm.a)
        throw new Error('[BotGuardClient]: Could not load program');

      var vmFunctionsCallback = function (
        asyncSnapshotFunction,
        shutdownFunction,
        passEventFunction,
        checkCameraFunction
      ) {
        bgVmFunctions = {
          asyncSnapshotFunction: asyncSnapshotFunction,
          shutdownFunction: shutdownFunction,
          passEventFunction: passEventFunction,
          checkCameraFunction: checkCameraFunction
        };
      };

      try {
        bgVm.a(bgProgram, vmFunctionsCallback, true, undefined, function () {}, [ [], [] ]);
      } catch (e) {
        throw new Error('[BotGuardClient]: Failed to execute program: ' + e.message);
      }

      return new Promise(function (resolve, reject) {
        var attempts = 0;
        var maxAttempts = 10000;
        var checkInterval = setInterval(function () {
          if (bgVmFunctions && bgVmFunctions.asyncSnapshotFunction) {
            clearInterval(checkInterval);
            resolve({
              vmFunctions: bgVmFunctions,
              vm: bgVm,
              program: bgProgram
            });
          } else if (attempts >= maxAttempts) {
            clearInterval(checkInterval);
            reject(new Error('[BotGuardClient]: Timeout waiting for asyncSnapshotFunction'));
          }
          attempts++;
        }, 1);
      });
    }

    function snapshot(botguard, args) {
      return new Promise(function (resolve, reject) {
        if (!botguard.vmFunctions || !botguard.vmFunctions.asyncSnapshotFunction) {
          return reject(new Error('[BotGuardClient]: Async snapshot function not found'));
        }

        try {
          botguard.vmFunctions.asyncSnapshotFunction(
            function (response) { resolve(response); },
            [
              args.contentBinding,
              args.signedTimestamp,
              args.webPoSignalOutput,
              args.skipPrivacyBuffer
            ]
          );
        } catch (e) {
          reject(new Error('[BotGuardClient]: Snapshot failed: ' + e.message));
        }
      });
    }

    function runBotGuard(challengeData) {
      var interpreterJavascript = challengeData.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue;

      if (interpreterJavascript) {
        new Function(interpreterJavascript)();
      } else {
        throw new Error('[BotGuardClient]: Could not load VM - no interpreter JavaScript');
      }

      var webPoSignalOutput = [];

      return loadBotGuard({
        globalName: challengeData.globalName,
        program: challengeData.program
      }).then(function (botguard) {
        return snapshot(botguard, { webPoSignalOutput: webPoSignalOutput });
      }).then(function (botguardResponse) {
        return { webPoSignalOutput: webPoSignalOutput, botguardResponse: botguardResponse };
      });
    }

    async function createPoTokenMinter(webPoSignalOutput, integrityToken) {
      var getMinter = webPoSignalOutput[0];
      if (!getMinter || typeof getMinter !== 'function') {
        throw new Error('[BotGuardClient]: webPoSignalOutput[0] minter factory is invalid');
      }

      var mintCallback;
      try {
        var minterResult = getMinter(integrityToken);
        if (minterResult && typeof minterResult.then === 'function') {
          mintCallback = await minterResult;
        } else {
          mintCallback = minterResult;
        }
      } catch (e) {
        throw new Error('[BotGuardClient]: getMinter() threw: ' + e.message);
      }

      if (!mintCallback || typeof mintCallback !== 'function') {
        throw new Error('[BotGuardClient]: mintCallback is invalid');
      }

      poTokenMinter = mintCallback;
    }

    async function obtainPoToken(identifier) {
      if (!poTokenMinter) {
        throw new Error('[BotGuardClient]: poTokenMinter not initialized');
      }

      var result;
      try {
        var mintResult = poTokenMinter(identifier);
        if (mintResult && typeof mintResult.then === 'function') {
          result = await mintResult;
        } else {
          result = mintResult;
        }
      } catch (e) {
        throw new Error('[BotGuardClient]: mintCallback() threw: ' + e.message);
      }

      if (!result || !(result instanceof Uint8Array)) {
        throw new Error('[BotGuardClient]: result is not Uint8Array');
      }

      return result;
    }
    BotGuardBridge.onPageLoaded();
    </script></head><body></body></html>
    """
}

// MARK: - BotGuard engine (headless WKWebView)

/// The script-message handler is a separate object because the handler
/// must be registered on the content controller before the WKWebView is
/// created, and `self` is not available that early in the engine's init.
private final class BotGuardMessageHandler: NSObject, WKScriptMessageHandler {
    weak var engine: BotGuardEngine?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        engine?.handleBridgeMessage(body)
    }
}

@MainActor
final class BotGuardEngine: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let messageHandler = BotGuardMessageHandler()
    private weak var owner: PoTokenGenerator?

    private var pageLoaded = false
    private var pageLoadedContinuation: CheckedContinuation<Void, Error>?
    private var challengeContinuation: CheckedContinuation<String, Error>?
    private var minterContinuation: CheckedContinuation<Void, Error>?
    private var pendingMints: [String: CheckedContinuation<String, Error>] = [:]
    private var pendingMintTasks: [String: Task<String, Error>] = [:]
    private var closed = false

    /// Set by the generator from the GenerateIT lifetime (minus a safety
    /// margin). An expired engine is rebuilt, never reused.
    var expiresAt: Date = .distantFuture

    var isExpired: Bool {
        closed || Date() > expiresAt
    }

    init(owner: PoTokenGenerator) {
        self.owner = owner
        let contentController = WKUserContentController()
        contentController.add(messageHandler, name: "BotGuardBridge")
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        messageHandler.engine = self
        webView.navigationDelegate = self
        webView.loadHTMLString(PoTokenGenerator.botGuardHTML, baseURL: URL(string: InnerTubeConstants.musicOrigin))
    }

    // MARK: - Bootstrap steps

    func waitForPageLoaded() async throws {
        if pageLoaded { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pageLoadedContinuation = continuation
        }
    }

    /// Runs the BotGuard challenge in the page; resolves with the
    /// BotGuard response string for GenerateIT.
    func runChallenge(_ challengeJSON: String) async throws -> String {
        let escaped = challengeJSON.replacingOccurrences(of: "<", with: "\\u003c")
        let script = """
        (function() {
          try {
            var data = \(escaped);
            runBotGuard(data).then(function(r) {
              window.webPoSignalOutput = r.webPoSignalOutput;
              BotGuardBridge.onBotGuardReady(r.botguardResponse);
            }, function(e) {
              BotGuardBridge.onFatalError(String(e) + "\\n" + (e.stack || ''));
            });
          } catch(e) { BotGuardBridge.onFatalError(String(e) + "\\n" + (e.stack || '')); }
        })();
        """
        _ = try await webView.evaluateJavaScript(script)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            challengeContinuation = continuation
        }
    }

    /// Creates the poToken minter from the GenerateIT integrity token.
    func createMinter(tokenU8JS: String) async throws {
        let script = """
        (function() {
          try {
            createPoTokenMinter(window.webPoSignalOutput, \(tokenU8JS)).then(function() {
              BotGuardBridge.onMinterReady();
            }).catch(function(e) {
              BotGuardBridge.onFatalError(String(e) + "\\n" + (e.stack || ''));
            });
          } catch(e) { BotGuardBridge.onFatalError(String(e) + "\\n" + (e.stack || '')); }
        })();
        """
        _ = try await webView.evaluateJavaScript(script)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            minterContinuation = continuation
        }
    }

    /// Mints one poToken for `identifier` (a video id, or the session id
    /// for the session token). Concurrent mints for the same identifier
    /// share one in-flight task, mirroring the Android engine.
    func mint(identifier: String) async throws -> String {
        guard !closed else { throw PoTokenError.engineNotReady }
        if let task = pendingMintTasks[identifier] {
            return try await task.value
        }
        let task = Task<String, Error> {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                pendingMints[identifier] = continuation
                Task { @MainActor in
                    await self.evaluateMint(identifier: identifier)
                }
            }
        }
        pendingMintTasks[identifier] = task
        do {
            let token = try await task.value
            pendingMintTasks.removeValue(forKey: identifier)
            return token
        } catch {
            pendingMintTasks.removeValue(forKey: identifier)
            throw error
        }
    }

    private func evaluateMint(identifier: String) async {
        let u8 = PoTokenGenerator.stringToJsUint8Array(identifier)
        let literal = Self.jsStringLiteral(identifier)
        let script = """
        (function() {
          try {
            obtainPoToken(\(u8)).then(function(u8) {
              BotGuardBridge.onMintOk(\(literal), Array.from(u8).join(","));
            }).catch(function(e) {
              BotGuardBridge.onMintErr(\(literal), String(e) + "\\n" + (e.stack || ''));
            });
          } catch(e) { BotGuardBridge.onMintErr(\(literal), String(e) + "\\n" + (e.stack || '')); }
        })();
        """
        do {
            _ = try await webView.evaluateJavaScript(script)
        } catch {
            pendingMints.removeValue(forKey: identifier)?.resume(throwing: error)
        }
    }

    // MARK: - Bridge

    func handleBridgeMessage(_ body: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else {
            return
        }
        switch event {
        case "onPageLoaded":
            pageLoaded = true
            pageLoadedContinuation?.resume()
            pageLoadedContinuation = nil
        case "onBotGuardReady":
            if let response = json["response"] as? String {
                challengeContinuation?.resume(returning: response)
            } else {
                challengeContinuation?.resume(throwing: PoTokenError.javaScriptError("BotGuard response missing"))
            }
            challengeContinuation = nil
        case "onMinterReady":
            minterContinuation?.resume()
            minterContinuation = nil
        case "onMintOk":
            if let id = json["id"] as? String, let csv = json["csv"] as? String {
                if let token = PoTokenGenerator.commaSeparatedBytesToBase64URL(csv) {
                    pendingMints.removeValue(forKey: id)?.resume(returning: token)
                } else {
                    pendingMints.removeValue(forKey: id)?.resume(throwing: PoTokenError.javaScriptError("Mint payload was not numeric CSV"))
                }
            }
        case "onMintErr":
            if let id = json["id"] as? String {
                pendingMints.removeValue(forKey: id)?.resume(throwing: PoTokenError.javaScriptError(json["error"] as? String ?? "Mint failed"))
            }
        case "onFatalError":
            failAll(with: PoTokenError.javaScriptError(json["error"] as? String ?? "BotGuard JS error"))
        default:
            break
        }
    }

    private func failAll(with error: Error) {
        pageLoadedContinuation?.resume(throwing: error)
        pageLoadedContinuation = nil
        challengeContinuation?.resume(throwing: error)
        challengeContinuation = nil
        minterContinuation?.resume(throwing: error)
        minterContinuation = nil
        for (_, continuation) in pendingMints {
            continuation.resume(throwing: error)
        }
        pendingMints.removeAll()
    }

    func close() {
        guard !closed else { return }
        closed = true
        failAll(with: PoTokenError.engineNotReady)
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "BotGuardBridge")
        webView.loadHTMLString("", baseURL: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failAll(with: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failAll(with: PoTokenError.javaScriptError("BotGuard WebView renderer terminated"))
        closed = true
    }

    private static func jsStringLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
}
