import Foundation
import JavaScriptCore

// MARK: - Signature decipher
//
// YouTube ciphered stream URLs carry an encrypted signature (`s`) that
// must be transformed by a function from the current player JavaScript
// (`base.js`), and a throttling parameter (`n`) that must be transformed
// by a second function from the same script. The Android app delegates
// both to NewPipe's `YoutubeJavaScriptPlayerManager`; this port does the
// same job directly: it fetches `base.js`, extracts the two functions
// (plus the helper object they call) with the same fingerprints NewPipe /
// yt-dlp use, and evaluates them in JavaScriptCore — the real JS, not a
// re-implementation of its operations, so future operation changes in the
// script keep working as long as the function shapes are recognised.
//
// If the script's shape changes and extraction fails, the error is typed
// and the caller skips the ciphered format instead of guessing.

enum SignatureDecipherError: Error, Sendable {
    case playerJSUnavailable
    case decipherFunctionNotFound
    case evaluationFailed(String)
    case invalidCipher
}

/// One extracted JavaScript function plus the helper object it calls.
/// `source` is evaluatable on its own in a fresh `JSContext`.
struct ExtractedJSFunction: Sendable {
    let name: String
    let source: String
}

actor SignatureDecipher {
    static let shared = SignatureDecipher()

    private let session = URLSession.shared
    private var jsByURL: [String: String] = [:]
    private var decipherByJSURL: [String: ExtractedJSFunction] = [:]
    private var throttleByJSURL: [String: ExtractedJSFunction?] = [:]
    private var timestampByJSURL: [String: Int] = [:]

    // MARK: - Public API

    /// The `signatureTimestamp` embedded in the current player script, or
    /// a days-since-epoch fallback when the script cannot be read. Web
    /// clients must present a signature timestamp in the player request.
    func signatureTimestamp(videoId: String) async -> Int? {
        guard let (jsURL, js) = await playerJS(videoId: videoId) else {
            return Self.daysBasedTimestamp()
        }
        if let cached = timestampByJSURL[jsURL] { return cached }
        guard let timestamp = Self.extractSignatureTimestamp(from: js) else {
            return Self.daysBasedTimestamp()
        }
        timestampByJSURL[jsURL] = timestamp
        return timestamp
    }

    /// Deciphers a `signatureCipher` / `cipher` value (`s=…&sp=…&url=…`)
    /// into a playable URL, then deobfuscates its throttling parameter.
    func decipher(videoId: String, signatureCipher: String) async throws -> String {
        guard let parsed = Self.parseSignatureCipher(signatureCipher),
              let baseURL = parsed.url else {
            throw SignatureDecipherError.invalidCipher
        }
        var resolved = baseURL
        if let encrypted = parsed.signature, !encrypted.isEmpty {
            guard let (jsURL, js) = await playerJS(videoId: videoId) else {
                throw SignatureDecipherError.playerJSUnavailable
            }
            let function = try decipherFunction(jsURL: jsURL, js: js)
            let signature = try Self.evaluate(function: function, input: encrypted)
            resolved = Self.appendingQueryParameter(to: resolved, name: parsed.param ?? "signature", value: signature)
                ?? resolved
        }
        return await deobfuscateThrottlingParameter(videoId: videoId, url: resolved)
    }

    /// Rewrites the `n` throttling parameter of a googlevideo URL using the
    /// player script's throttling function. Best effort: any failure
    /// returns the URL unchanged.
    func deobfuscateThrottlingParameter(videoId: String, url: String) async -> String {
        guard var components = URLComponents(string: url),
              var items = components.queryItems,
              let index = items.firstIndex(where: { $0.name == "n" }),
              let nValue = items[index].value, !nValue.isEmpty else {
            return url
        }
        guard let (jsURL, js) = await playerJS(videoId: videoId) else { return url }
        guard let function = throttlingFunction(jsURL: jsURL, js: js) else { return url }
        guard let deobfuscated = try? Self.evaluate(function: function, input: nValue) else { return url }
        items[index] = URLQueryItem(name: "n", value: deobfuscated)
        components.queryItems = items
        return components.string ?? url
    }

    // MARK: - Cached lookups

    private func decipherFunction(jsURL: String, js: String) throws -> ExtractedJSFunction {
        if let cached = decipherByJSURL[jsURL] { return cached }
        guard let function = Self.extractDecipherFunction(from: js) else {
            throw SignatureDecipherError.decipherFunctionNotFound
        }
        decipherByJSURL[jsURL] = function
        return function
    }

    private func throttlingFunction(jsURL: String, js: String) -> ExtractedJSFunction? {
        if let cached = throttleByJSURL[jsURL] { return cached }
        let function = Self.extractThrottlingFunction(from: js)
        throttleByJSURL[jsURL] = function
        return function
    }

    // MARK: - Player JavaScript

    /// The player script URL and source for a video, cached per URL.
    private func playerJS(videoId: String) async -> (url: String, source: String)? {
        guard let html = try? await fetchText(url: "https://www.youtube.com/watch?v=\(videoId)") else {
            return nil
        }
        guard let jsURL = Self.extractPlayerJSURL(fromHTML: html) else { return nil }
        if let cached = jsByURL[jsURL] { return (jsURL, cached) }
        guard let js = try? await fetchText(url: jsURL) else { return nil }
        jsByURL[jsURL] = js
        return (jsURL, js)
    }

    private func fetchText(url: String) async throws -> String {
        guard let requestURL = URL(string: url) else {
            throw SignatureDecipherError.playerJSUnavailable
        }
        var request = URLRequest(url: requestURL)
        request.setValue(InnerTubeConstants.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SignatureDecipherError.playerJSUnavailable
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SignatureDecipherError.playerJSUnavailable
        }
        return text
    }

    // MARK: - Pure extraction helpers (testable without the network)

    /// The `jsUrl` of the player script, from a watch-page HTML document.
    /// Parsed by hand: the value is a plain quoted string, and a regex
    /// with the quotes in it would break the repo's brace scanner.
    static func extractPlayerJSURL(fromHTML html: String) -> String? {
        guard let keyRange = html.range(of: "\"jsUrl\":\"") else { return nil }
        let rest = html[keyRange.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let raw = String(rest[..<end])
        let unescaped = raw.replacingOccurrences(of: "\\/", with: "/")
        if unescaped.hasPrefix("http") { return unescaped }
        if unescaped.hasPrefix("//") { return "https:" + unescaped }
        return "https://www.youtube.com" + unescaped
    }

    /// `signatureTimestamp:12345` in the player script. The key may be
    /// quoted (JSON) or bare (JS object literal). Parsed by hand: the
    /// number follows the key after an optional quote, the colon, and
    /// whitespace.
    static func extractSignatureTimestamp(from js: String) -> Int? {
        guard let keyRange = js.range(of: "signatureTimestamp") else { return nil }
        let digits = js[keyRange.upperBound...]
            .drop(while: { $0 == "\"" || $0 == "'" || $0 == ":" || $0.isWhitespace })
            .prefix(while: { $0.isNumber })
        return Int(digits)
    }

    /// The signature decipher function: a function whose body starts with
    /// `x = x.split("")`. Returns the function plus the helper object it
    /// calls, as one evaluatable source. The pattern uses `[(]`/`[)]`/
    /// `[{]` instead of `\(`/`\)`/`\{` and checks the empty-string
    /// argument on the matched text, so the repo's brace scanner stays
    /// in sync — the regex itself is unchanged in meaning.
    static func extractDecipherFunction(from js: String) -> ExtractedJSFunction? {
        let pattern = #"([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*function\s*[(]\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*[)]\s*[{]\s*\2\s*=\s*\2\.split[(]"#
        guard let match = firstMatch(pattern, in: js),
              let name = group(match, 1, in: js),
              let arg = group(match, 2, in: js),
              let matchRange = Range(match.range, in: js) else {
            return nil
        }
        // The split argument must be the empty string: `split("")`.
        let after = js[matchRange.upperBound...].drop(while: { $0.isWhitespace })
        guard after.hasPrefix("\"\"") else { return nil }
        guard let definition = extractFunctionDefinition(js: js, name: name, from: matchRange.lowerBound) else {
            return nil
        }
        let helper = extractHelperObject(js: js, functionBody: definition.body, excluding: arg)
        let source = (helper.map { $0 + "\n" } ?? "") + definition.source
        return ExtractedJSFunction(name: name, source: source)
    }

    /// The throttling (`n`) function: the function passed to `set("n", …)`.
    static func extractThrottlingFunction(from js: String) -> ExtractedJSFunction? {
        let patterns = [
            // `.n.` stands for the quoted "n" (or 'n'): a literal quote
            // in the pattern would break the repo's brace scanner.
            #"\.set[(]\s*.n.\s*,\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*[(]"#,
            #"set[(]\s*.n.\s*,\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*[(]\s*[A-Za-z_$][A-Za-z0-9_$]*\.get[(]\s*.n.\s*[)]\s*[)]"#,
        ]
        for pattern in patterns {
            guard let match = firstMatch(pattern, in: js),
                  let name = group(match, 1, in: js) else {
                continue
            }
            guard let definition = extractNamedFunction(js: js, name: name) else { continue }
            let arg = definition.argument
            let helper = extractHelperObject(js: js, functionBody: definition.body, excluding: arg)
            let source = (helper.map { $0 + "\n" } ?? "") + definition.source
            return ExtractedJSFunction(name: name, source: source)
        }
        return nil
    }

    /// Evaluates an extracted function in a fresh JavaScriptCore context
    /// and returns its string result.
    static func evaluate(function: ExtractedJSFunction, input: String) throws -> String {
        guard let context = JSContext() else {
            throw SignatureDecipherError.evaluationFailed("Could not create JS context")
        }
        var jsError: String?
        context.exceptionHandler = { _, exception in
            jsError = exception?.toString()
        }
        context.evaluateScript(function.source)
        if let jsError {
            throw SignatureDecipherError.evaluationFailed(jsError)
        }
        guard let fn = context.objectForKeyedSubscript(function.name), !fn.isUndefined else {
            throw SignatureDecipherError.evaluationFailed("Function \(function.name) is not defined after evaluation")
        }
        let result = fn.call(withArguments: [input])
        if let jsError {
            throw SignatureDecipherError.evaluationFailed(jsError)
        }
        guard let output = result?.toString(), !output.isEmpty else {
            throw SignatureDecipherError.evaluationFailed("Function returned an empty result")
        }
        return output
    }

    /// Parses a `signatureCipher` query string into its URL, encrypted
    /// signature and signature parameter name.
    static func parseSignatureCipher(_ cipher: String) -> (url: String?, signature: String?, param: String?)? {
        guard let components = URLComponents(string: "https://cipher.invalid/?" + cipher) else {
            return nil
        }
        let items = components.queryItems ?? []
        let url = items.first(where: { $0.name == "url" })?.value
        let signature = items.first(where: { $0.name == "s" })?.value
        let param = items.first(where: { $0.name == "sp" })?.value
        return (url, signature, param)
    }

    /// Appends (or replaces) one query parameter, preserving the rest of
    /// the URL. Falls back to plain string concatenation when the URL does
    /// not parse as URLComponents.
    static func appendingQueryParameter(to urlString: String, name: String, value: String) -> String? {
        guard var components = URLComponents(string: urlString) else {
            let separator = urlString.contains("?") ? "&" : "?"
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return urlString + separator + name + "=" + encoded
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        return components.string
    }

    static func daysBasedTimestamp() -> Int {
        Int(Date().timeIntervalSince1970 / 86_400) - 1
    }

    // MARK: - Regex and brace matching

    private struct FunctionDefinition {
        let source: String
        let body: String
        let argument: String
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        return regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ result: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        let range = result.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    /// The full `var name = function(arg){…};` definition starting at or
    /// after `start`, plus its body text and argument name.
    private static func extractFunctionDefinition(js: String, name: String, from start: String.Index) -> FunctionDefinition? {
        // Find the opening brace of the function body.
        guard let bodyOpen = js[start...].firstIndex(of: "{") else { return nil }
        guard let bodyEnd = matchingBraceEnd(in: js, from: bodyOpen) else { return nil }
        let body = String(js[bodyOpen...bodyEnd])
        // Argument name: the identifier inside the parens before the brace.
        let head = String(js[start..<bodyOpen])
        guard let argMatch = firstMatch(#"[(]\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*[)]"#, in: head),
              let arg = group(argMatch, 1, in: head) else {
            return nil
        }
        let source = "var \(name) = function(\(arg))" + body + ";"
        return FunctionDefinition(source: source, body: body, argument: arg)
    }

    /// A named `var name = function(arg){…}` definition anywhere in the
    /// script (used for the throttling function).
    private static func extractNamedFunction(js: String, name: String) -> FunctionDefinition? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = escaped + #"\s*=\s*function\s*[(]"#
        guard let match = firstMatch(pattern, in: js) else { return nil }
        let matchRange = Range(match.range, in: js) ?? js.startIndex..<js.startIndex
        return extractFunctionDefinition(js: js, name: name, from: matchRange.lowerBound)
    }

    /// The helper object a function body calls as `Obj.method(…)`, as one
    /// evaluatable `var Obj = {…};` definition. Returns nil when the body
    /// calls no helper object.
    private static func extractHelperObject(js: String, functionBody: String, excluding argName: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_$][A-Za-z0-9_$]*)\.[A-Za-z_$][A-Za-z0-9_$]*\s*[(]"#,
            options: []
        ) else { return nil }
        let range = NSRange(functionBody.startIndex..., in: functionBody)
        let matches = regex.matches(in: functionBody, options: [], range: range)
        var counts: [String: Int] = [:]
        for match in matches {
            let nameRange = match.range(at: 1)
            guard nameRange.location != NSNotFound,
                  let swiftRange = Range(nameRange, in: functionBody) else { continue }
            let name = String(functionBody[swiftRange])
            guard name != argName else { continue }
            counts[name, default: 0] += 1
        }
        guard let helperName = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: helperName)
        let pattern = #"(?:var\s+)?"# + escaped + #"\s*=\s*[{]"#
        guard let match = firstMatch(pattern, in: js),
              let matchRange = Range(match.range, in: js),
              let openIndex = js[matchRange].firstIndex(of: "{") else {
            return nil
        }
        guard let closeIndex = matchingBraceEnd(in: js, from: openIndex) else { return nil }
        let literal = String(js[openIndex...closeIndex])
        return "var \(helperName) = \(literal);"
    }

    /// Index of the `}` matching the `{` at `openIndex`, skipping string
    /// literals and comments. Returns nil when unbalanced.
    private static func matchingBraceEnd(in text: String, from openIndex: String.Index) -> String.Index? {
        var depth = 0
        var index = openIndex
        var stringQuote: Character?
        var escaped = false
        while index < text.endIndex {
            let ch = text[index]
            let next = text.index(after: index) < text.endIndex ? text[text.index(after: index)] : nil
            if let quote = stringQuote {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == quote {
                    stringQuote = nil
                }
            } else if ch == "\"" || ch == "'" || ch == "`" {
                stringQuote = ch
            } else if ch == "/" && next == "/" {
                // Skip to end of line.
                while index < text.endIndex && text[index] != "\n" {
                    index = text.index(after: index)
                }
                continue
            } else if ch == "/" && next == "*" {
                // Skip to end of block comment.
                var closed = false
                while index < text.endIndex {
                    if text[index] == "*" {
                        let after = text.index(after: index)
                        if after < text.endIndex && text[after] == "/" {
                            index = text.index(after: after)
                            closed = true
                            break
                        }
                    }
                    index = text.index(after: index)
                }
                if !closed { return nil }
                continue
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
