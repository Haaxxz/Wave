import SwiftUI

/// Spotify sign-in. Spotify's Web API needs a developer app of your own:
/// enter its client id and client secret below, then tap Connect. Wave
/// validates them by loading your Spotify liked songs; a failure means
/// the credentials (or the app's redirect setup) are wrong, and the
/// error is shown here.
struct SpotifyLoginView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router

    @State private var isConnecting = false
    @State private var statusMessage: String?
    @State private var isConnected = false
    @State private var likedCount = 0

    var body: some View {
        Form {
            Section("Your Spotify developer app") {
                TextField("Client ID", text: $settings.spotifyClientId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Client secret", text: $settings.spotifyClientSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Create the app at developer.spotify.com — it is free, and its credentials stay on this device.")
                    .font(.footnote)
                    .foregroundStyle(WaveColors.secondaryLabel)
            }

            Section {
                Button("Connect") {
                    Task { await connect() }
                }
                .disabled(!canConnect || isConnecting)
                if isConnecting {
                    ProgressView("Checking your Spotify credentials…")
                }
                if let statusMessage {
                    Text(statusMessage)
                        .foregroundStyle(isConnected ? .green : .red)
                }
            }

            if isConnected {
                Section {
                    HStack {
                        Text("Liked songs on Spotify")
                        Spacer()
                        Text("\(likedCount)")
                            .foregroundStyle(WaveColors.secondaryLabel)
                    }
                    Button("Import a playlist") {
                        router.navigate(.playlistImport, in: router.selectedTab)
                    }
                }
            }

            Section("What this enables") {
                Text("Playlist import needs your own Spotify developer app — Spotify does not offer a shared login for third-party clients. Wave uses the client credentials flow, so no Spotify password is ever entered or stored here.")
                    .font(.footnote)
                    .foregroundStyle(WaveColors.secondaryLabel)
            }
        }
        .navigationTitle("Spotify sign-in")
    }

    private var canConnect: Bool {
        !settings.spotifyClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.spotifyClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Validates the credentials against the real Spotify API. A throw
    /// here means the credentials are wrong or Spotify is unreachable —
    /// either way, nothing is saved as "connected".
    private func connect() async {
        isConnecting = true
        statusMessage = nil
        isConnected = false
        defer { isConnecting = false }
        do {
            let liked = try await SpotifyService.shared.likedSongs()
            likedCount = liked.count
            isConnected = true
            statusMessage = "Connected — found \(liked.count) liked songs on Spotify."
        } catch {
            statusMessage = "Could not connect: \(error.localizedDescription)"
        }
    }
}
