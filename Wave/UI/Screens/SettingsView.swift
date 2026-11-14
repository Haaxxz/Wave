import SwiftUI

/// App settings: account, playback, appearance, downloads, storage,
/// modules and integrations. Everything binds to `SettingsStore`.
struct SettingsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            accountSection
            playbackSection
            librarySection
            integrationsSection
            aboutSection
        }
        .navigationTitle("Settings")
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
            if settings.isLoggedIn {
                HStack {
                    Image(systemName: "person.circle.fill")
                        .font(.title2)
                        .foregroundStyle(WaveColors.accent)
                    VStack(alignment: .leading) {
                        Text(settings.userName.isEmpty ? "YouTube Music" : settings.userName)
                            .font(WaveFonts.headline())
                        Text("YouTube Music")
                            .font(.footnote)
                            .foregroundStyle(WaveColors.secondaryLabel)
                    }
                    Spacer()
                    Button("Sign out", role: .destructive) {
                        settings.signOut()
                    }
                }
            } else {
                Button {
                    router.navigate(.youtubeLogin, in: router.selectedTab)
                } label: {
                    Label("Sign in with YouTube", systemImage: "play.rectangle.fill")
                }
                Button {
                    router.navigate(.spotifyLogin, in: router.selectedTab)
                } label: {
                    Label("Connect Spotify", systemImage: "music.note.list")
                }
            }
        }
    }

    // MARK: - Playback & library

    private var playbackSection: some View {
        Section("Playback") {
            NavigationLink {
                AudioSettingsView()
            } label: {
                Label("Audio", systemImage: "speaker.wave.2.fill")
            }
            NavigationLink {
                AppearanceSettingsView()
            } label: {
                Label("Appearance", systemImage: "paintpalette.fill")
            }
            NavigationLink {
                AutoEQView()
            } label: {
                Label("AutoEQ", systemImage: "slider.horizontal.3")
            }
            NavigationLink {
                DownloadSettingsView()
            } label: {
                Label("Downloads", systemImage: "arrow.down.circle.fill")
            }
            NavigationLink {
                StorageView()
            } label: {
                Label("Storage", systemImage: "internaldrive.fill")
            }
        }
    }

    private var librarySection: some View {
        Section("Library") {
            NavigationLink {
                ModulesView()
            } label: {
                Label("Modules", systemImage: "square.stack.3d.up.fill")
            }
            NavigationLink {
                ExcludedSongsView()
            } label: {
                Label("Excluded songs", systemImage: "eye.slash.fill")
            }
            NavigationLink {
                HomeSectionsView()
            } label: {
                Label("Home sections", systemImage: "rectangle.grid.2x2.fill")
            }
        }
    }

    // MARK: - Integrations

    private var integrationsSection: some View {
        Section("Integrations") {
            SecureField("Last.fm API key", text: $settings.lastFmApiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Spotify client ID", text: $settings.spotifyClientId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Spotify client secret", text: $settings.spotifyClientSecret)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text("Last.fm scrobbling uses your API key. Spotify playlist import needs your own Spotify developer app — see the Spotify login screen for details.")
                .font(.footnote)
                .foregroundStyle(WaveColors.secondaryLabel)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text("0.1.0")
                    .foregroundStyle(WaveColors.secondaryLabel)
            }
            HStack {
                Text("Licence")
                Spacer()
                Text("GPLv3")
                    .foregroundStyle(WaveColors.secondaryLabel)
            }
            Link(destination: URL(string: "https://github.com/lastwave-ios/wave")!) {
                Label("Wave on GitHub", systemImage: "link")
            }
            Text("Wave is an unofficial, non-commercial YouTube Music client. It is not affiliated with YouTube, Google or Spotify.")
                .font(.footnote)
                .foregroundStyle(WaveColors.secondaryLabel)
        }
    }
}
