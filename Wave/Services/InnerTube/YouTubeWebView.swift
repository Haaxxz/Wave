import SwiftUI
import WebKit

// MARK: - YouTube login WebView
//
// Loads the YouTube Music login page in a WKWebView. When the session
// cookies show a logged-in user (a `SAPISID` cookie for youtube.com),
// the account display name is read through the page's own
// `account_menu` endpoint — same origin, so the session cookies ride
// along — and `onLoginComplete` fires with it (nil when the name cannot
// be read, or when the login flow fails). The caller (LoginView) owns
// dismissal and writes the result into `SettingsStore`; this view only
// reports. Cookies land in the shared cookie storage, which is what
// `YouTubeSession` reads for the SAPISIDHASH header.

struct YouTubeWebView: UIViewRepresentable {
    var onLoginComplete: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: InnerTubeConstants.musicOrigin + "/")!))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: YouTubeWebView
        private var completed = false

        init(parent: YouTubeWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkLogin(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // A failed navigation is not a failed login: the sign-in flow
            // may still complete on a later navigation.
        }

        private func checkLogin(_ webView: WKWebView) {
            guard !completed else { return }
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let loggedIn = cookies.contains {
                    $0.name == "SAPISID" && $0.domain.contains("youtube.com")
                }
                guard loggedIn else { return }
                self.fetchAccountName(webView)
            }
        }

        private func fetchAccountName(_ webView: WKWebView) {
            // The account_menu endpoint returns the signed-in account,
            // including `accountName.simpleText`, deep in its JSON.
            let javaScript = """
            (async () => {
              try {
                const r = await fetch('/youtubei/v1/account/account_menu?key=\(InnerTubeConstants.fallbackAPIKey)&prettyPrint=false', {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ context: { client: { clientName: 'WEB_REMIX', clientVersion: '\(InnerTubeConstants.fallbackClientVersion)', hl: 'en', gl: 'US' } } })
                });
                return await r.text();
              } catch (e) { return null; }
            })()
            """
            Task { @MainActor in
                let result = try? await webView.evaluateJavaScript(javaScript)
                let name = (result as? String).flatMap { text -> String? in
                    guard let data = text.data(using: .utf8),
                          let json = try? JSONValue(data: data) else {
                        return nil
                    }
                    return json.findAccountName()
                }
                self.complete(with: name)
            }
        }

        private func complete(with name: String?) {
            guard !completed else { return }
            completed = true
            parent.onLoginComplete(name)
        }
    }
}
