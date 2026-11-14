import XCTest
@testable import Wave

// MARK: - Signature decipher tests
//
// No network: extraction and evaluation run against small hand-made
// player-JS fragments that use the same shapes as the real `base.js`
// (a decipher function starting with `x = x.split("")`, a helper object
// of reverse/splice/swap operations, and a throttling function passed to
// `set("n", …)`).

final class SignatureDecipherTests: XCTestCase {

    /// A decipher function plus helper object, in real `base.js` shape:
    /// reverse, then swap(0, 3), then splice(0, 2).
    private let decipherJS = """
    var Xy = {
      a: function(a,b){var c=a[0];a[0]=a[b%a.length];a[b%a.length]=c},
      b: function(a){a.reverse()},
      c: function(a,b){a.splice(0,b)}
    };
    var Qz = function(a){a=a.split("");Xy.b(a);Xy.a(a,3);Xy.c(a,2);return a.join("")};
    """

    /// A throttling function, referenced the way `base.js` references it.
    private let throttleJS = """
    var Nn = {
      r: function(a){a.reverse()},
      s: function(a,b){a.splice(0,b)}
    };
    var NnFn = function(a){a=a.split("");Nn.r(a);Nn.s(a,1);return a.join("")};
    var setter = { set: function(k, v){ this[k] = v; } };
    setter.set("n", NnFn(setter.get("n")));
    """

    func testExtractDecipherFunction() throws {
        guard let function = SignatureDecipher.extractDecipherFunction(from: decipherJS) else {
            XCTFail("Decipher function was not extracted")
            return
        }
        XCTAssertEqual(function.name, "Qz")
        // The helper object travels with the function source.
        XCTAssertTrue(function.source.contains("var Xy = {"))
        XCTAssertTrue(function.source.contains("var Qz = function"))
        // "abcdefgh" -> reverse -> swap(0,3) -> splice(0,2) -> "fhdcba".
        XCTAssertEqual(try SignatureDecipher.evaluate(function: function, input: "abcdefgh"), "fhdcba")
    }

    func testExtractDecipherFunctionNotFound() {
        let js = "var a = 1; function unrelated(x) { return x + 1; }"
        XCTAssertNil(SignatureDecipher.extractDecipherFunction(from: js))
    }

    func testExtractThrottlingFunction() throws {
        guard let function = SignatureDecipher.extractThrottlingFunction(from: throttleJS) else {
            XCTFail("Throttling function was not extracted")
            return
        }
        XCTAssertEqual(function.name, "NnFn")
        // "abcdef" -> reverse -> splice(0,1) -> "edcba".
        XCTAssertEqual(try SignatureDecipher.evaluate(function: function, input: "abcdef"), "edcba")
    }

    func testExtractThrottlingFunctionNotFound() {
        XCTAssertNil(SignatureDecipher.extractThrottlingFunction(from: "var a = 1;"))
    }

    func testEvaluateFailure() {
        let function = ExtractedJSFunction(
            name: "Nope",
            source: "var Nope = function(a){ throw new Error('boom'); };"
        )
        XCTAssertThrowsError(try SignatureDecipher.evaluate(function: function, input: "abc"))
    }

    func testExtractSignatureTimestamp() {
        let js = "var x = {signatureTimestamp:12345, other: 1};"
        XCTAssertEqual(SignatureDecipher.extractSignatureTimestamp(from: js), 12345)
        let quoted = #"{"signatureTimestamp": 98765}"#
        XCTAssertEqual(SignatureDecipher.extractSignatureTimestamp(from: quoted), 98765)
        XCTAssertNil(SignatureDecipher.extractSignatureTimestamp(from: "var x = 1;"))
    }

    func testExtractPlayerJSURL() {
        let html = #"<script>ytcfg.set({"PLAYER_CONFIG": {"args": {"raw_player_response": {}}}});</script><link rel="stylesheet" href="/x"><script>var ytcfg = {"jsUrl":"\/s\/player\/abc123\/player_ias.vflset\/en_US\/base.js"};</script>"#
        XCTAssertEqual(
            SignatureDecipher.extractPlayerJSURL(fromHTML: html),
            "https://www.youtube.com/s/player/abc123/player_ias.vflset/en_US/base.js"
        )
        XCTAssertNil(SignatureDecipher.extractPlayerJSURL(fromHTML: "<html></html>"))
    }

    func testParseSignatureCipher() {
        let cipher = "s=SIG123&sp=sig&url=https%3A%2F%2Fexample.com%2Fvideoplayback%3Fitag%3D140"
        guard let parsed = SignatureDecipher.parseSignatureCipher(cipher) else {
            XCTFail("Cipher was not parsed")
            return
        }
        XCTAssertEqual(parsed.url, "https://example.com/videoplayback?itag=140")
        XCTAssertEqual(parsed.signature, "SIG123")
        XCTAssertEqual(parsed.param, "sig")

        // No signature parameter: the URL is still usable as-is.
        let noSignature = "url=https%3A%2F%2Fexample.com%2Fvideoplayback"
        guard let plain = SignatureDecipher.parseSignatureCipher(noSignature) else {
            XCTFail("Cipher without signature was not parsed")
            return
        }
        XCTAssertEqual(plain.url, "https://example.com/videoplayback")
        XCTAssertNil(plain.signature)
        XCTAssertNil(plain.param)
    }

    func testAppendingQueryParameter() {
        XCTAssertEqual(
            SignatureDecipher.appendingQueryParameter(to: "https://example.com/v?a=1", name: "sig", value: "abc"),
            "https://example.com/v?a=1&sig=abc"
        )
        XCTAssertEqual(
            SignatureDecipher.appendingQueryParameter(to: "https://example.com/v?a=1&sig=old", name: "sig", value: "new"),
            "https://example.com/v?a=1&sig=new"
        )
    }
}
