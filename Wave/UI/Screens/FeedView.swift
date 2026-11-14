import SwiftUI

// MARK: - Feed (home)

/// The home feed: sections from YouTube Music rendered as horizontal card
/// rows. Shows a sign-in banner when the user is not logged in, and
/// loading / error / empty states while the feed loads.
struct FeedView: View {
    @Environment(InnerTubeClient.self) private var innerTube
    @Environment(SettingsStore.self) private var settings

    @State private var sections: [FeedSection] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !settings.isLoggedIn {
                    signInBanner
                        .padding(.horizontal)
                }

                if isLoading {
                    LoadingShimmerView(rows: 4)
                    LoadingCardRowView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                } else if sections.isEmpty {
                    emptyState
                } else {
                    ForEach(sections) { section in
                        SectionRow(section: section)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("Feed")
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Subviews

    private var signInBanner: some View {
        NavigationLink(value: Route.youtubeLogin) {
            HStack(spacing: 12) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(WaveColors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in to YouTube")
                        .font(WaveFonts.headline())
                    Text("Sync likes, history and your library. Optional — the app works without it.")
                        .font(WaveFonts.body(13))
                        .foregroundStyle(WaveColors.secondaryLabel)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WaveColors.secondaryLabel)
            }
            .padding(14)
            .waveGlassBackground(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 36))
                .foregroundStyle(WaveColors.secondaryLabel)
            Text("Nothing here yet")
                .font(WaveFonts.headline())
            Text("Pull down to refresh, or sign in to YouTube for a personalised feed.")
                .font(WaveFonts.body(14))
                .foregroundStyle(WaveColors.secondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            sections = try await innerTube.home()
        } catch {
            errorMessage = "Something went wrong loading this."
        }
        isLoading = false
    }
}
