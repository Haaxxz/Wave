import SwiftUI

/// YouTube Music sign-in, hosted in an in-app web view.
/// The web view loads the YouTube Music login page; when the session
/// cookies show a logged-in user it calls back with the account display
/// name. The cookies stay on the device and are only attached to
/// YouTube Music requests — Wave never sees or stores your password.
struct YouTubeLoginView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            YouTubeWebView { displayName in
                settings.isLoggedIn = true
                settings.userName = displayName ?? ""
                dismiss()
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("How login works", systemImage: "lock.shield.fill")
                    .font(WaveFonts.headline())
                Text("Sign in with your Google account in the page above. Wave keeps only the session cookies, on this device, and uses them to load your library, likes and history from YouTube Music. Your password is never seen or stored by Wave, and you can sign out any time from Settings.")
                    .font(.footnote)
                    .foregroundStyle(WaveColors.secondaryLabel)
            }
            .padding()
            .background(WaveColors.secondaryBackground)
        }
        .navigationTitle("YouTube sign-in")
        .navigationBarTitleDisplayMode(.inline)
    }
}
