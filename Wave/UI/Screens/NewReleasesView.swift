import SwiftUI

// MARK: - New releases

/// New releases from YouTube Music, shown as a two-column grid of album
/// cards. Tapping a card opens the album.
struct NewReleasesView: View {
    @Environment(InnerTubeClient.self) private var innerTube

    @State private var albums: [AlbumRef] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            if isLoading {
                LoadingCardRowView()
                    .padding(.top, 16)
            } else if let errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task { await load() }
                }
            } else if albums.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(albums) { album in
                        NavigationLink(value: Route.album(id: album.id)) {
                            AlbumCard(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("New Releases")
        .task { await load() }
        .refreshable { await load() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(WaveColors.secondaryLabel)
            Text("No new releases right now")
                .font(WaveFonts.headline())
            Text("Pull down to refresh and try again.")
                .font(WaveFonts.body(14))
                .foregroundStyle(WaveColors.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            albums = try await innerTube.newReleases()
        } catch {
            errorMessage = "Something went wrong loading this."
        }
        isLoading = false
    }
}
