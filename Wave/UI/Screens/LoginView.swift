import SwiftUI

/// Sign-in hub: YouTube, Spotify, or continue without an account.
/// YouTube sign-in opens an in-app web view (see `YouTubeLoginView`);
/// the session cookies stay on the device and are only used for
/// YouTube Music requests. Nothing is uploaded anywhere.
struct LoginView: View {
    @Environment(AppRouter.self) private var router
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 48)

                Image(systemName: "waveform")
                    .font(.system(size: 64))
                    .foregroundStyle(WaveColors.accent)

                Text("Welcome to Wave")
                    .font(WaveFonts.title())

                Text("Sign in to sync your YouTube Music library, likes and history — or keep listening without an account.")
                    .font(WaveFonts.body())
                    .foregroundStyle(WaveColors.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if settings.isLoggedIn {
                    signedInCard
                } else {
                    signInButtons
                }

                Spacer(minLength: 32)
            }
        }
        .navigationTitle("Sign in")
    }

    private var signedInCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(WaveColors.accent)
            Text("Signed in as \(settings.userName.isEmpty ? "YouTube Music" : settings.userName)")
                .font(WaveFonts.headline())
            Button("Sign out", role: .destructive) {
                settings.signOut()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .waveGlassBackground()
        .padding(.horizontal)
    }

    private var signInButtons: some View {
        VStack(spacing: 12) {
            Button {
                router.navigate(.youtubeLogin, in: router.selectedTab)
            } label: {
                Label("Continue with YouTube", systemImage: "play.rectangle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                router.navigate(.spotifyLogin, in: router.selectedTab)
            } label: {
                Label("Continue with Spotify", systemImage: "music.note.list")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button("Continue without signing in") {
                settings.hasCompletedOnboarding = true
                router.popToRoot(in: router.selectedTab)
                router.selectedTab = .feed
            }
            .buttonStyle(.plain)
            .foregroundStyle(WaveColors.accent)
            .padding(.top, 8)

            Text("Without signing in you can still browse, play music and use downloads. Likes and library sync need an account.")
                .font(.footnote)
                .foregroundStyle(WaveColors.secondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 4)
        }
        .padding(.horizontal)
    }
}
