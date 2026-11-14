import SwiftUI

/// A friend's public profile.
///
/// In the Android app, friend profiles come from Last.fm. This build's
/// `LastFmService` only exposes whether Last.fm is configured (plus
/// scrobbling) — it has no friends/top-tracks endpoint — so the profile
/// shows the friend's identity and the shared-taste section is built
/// from your own library, labelled as such. When Last.fm is not linked,
/// the screen explains that and links to Settings.
struct FriendProfileView: View {
    var userId: String

    @Environment(AppRouter.self) private var router
    @Environment(LibraryStoreImpl.self) private var library
    @Environment(Player.self) private var player

    init(userId: String) {
        self.userId = userId
    }

    var body: some View {
        Group {
            if LastFmService.shared.isConfigured {
                profileContent
            } else {
                notConfigured
            }
        }
        .navigationTitle(userId)
    }

    // MARK: - Configured: profile + shared taste

    private var profileContent: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(WaveColors.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(userId)
                            .font(WaveFonts.title(20))
                        Text("Last.fm user")
                            .font(.footnote)
                            .foregroundStyle(WaveColors.secondaryLabel)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if library.likedSongs.isEmpty {
                    Text("Like some songs first — your liked songs are the starting point for comparing taste with \(userId).")
                        .font(.footnote)
                        .foregroundStyle(WaveColors.secondaryLabel)
                } else {
                    Text("A full Last.fm friend chart needs the Last.fm friends endpoint, which is not wired up in this build. Until then, here are your most-played liked songs — a starting point for shared taste.")
                        .font(.footnote)
                        .foregroundStyle(WaveColors.secondaryLabel)
                    ForEach(sharedTasteTracks) { track in
                        TrackRow(track: track)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(track) }
                    }
                }
            } header: {
                Text("Shared taste")
            }
        }
    }

    /// Your liked songs ranked by play count — the closest this build
    /// gets to a shared-taste list without a Last.fm friends endpoint.
    private var sharedTasteTracks: [Track] {
        Array(library.likedSongs
            .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
            .prefix(10))
    }

    // MARK: - Not configured

    private var notConfigured: some View {
        ContentUnavailableView(
            "Last.fm is not linked",
            systemImage: "person.2.slash",
            description: Text("Friend profiles need Last.fm. Add your Last.fm API key in Settings to see \(userId)'s profile.")
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Open Settings") {
                    router.navigate(.settings, in: router.selectedTab)
                }
            }
        }
    }
}
