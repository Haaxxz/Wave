import SwiftUI

// MARK: - Artist detail

/// Artist page: header with artwork, name and subscriber count, Shuffle and
/// Follow actions, top songs, then albums, singles and playlists rows.
struct ArtistView: View {
    var id: String

    init(id: String) {
        self.id = id
    }

    @Environment(InnerTubeClient.self) private var innerTube
    @Environment(Player.self) private var player

    @State private var detail: ArtistDetail? = nil
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isFollowing = false

    var body: some View {
        ScrollView {
            if isLoading {
                LoadingShimmerView(rows: 8)
                    .padding(.top, 16)
            } else if let errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task { await load() }
                }
            } else if let detail {
                artistContent(detail)
            } else {
                ErrorStateView(message: "This artist could not be found.") {
                    Task { await load() }
                }
            }
        }
        .navigationTitle(detail?.name ?? "Artist")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Content

    private func artistContent(_ detail: ArtistDetail) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            header(detail)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            if !detail.topSongs.isEmpty {
                topSongsSection(detail)
            }

            if !detail.albums.isEmpty {
                SectionRow(section: FeedSection(
                    title: "Albums",
                    items: detail.albums.map { .album($0) }
                ))
            }

            if !detail.singles.isEmpty {
                SectionRow(section: FeedSection(
                    title: "Singles",
                    items: detail.singles.map { .album($0) }
                ))
            }

            if !detail.playlists.isEmpty {
                SectionRow(section: FeedSection(
                    title: "Playlists",
                    items: detail.playlists.map { .playlist($0) }
                ))
            }
        }
        .padding(.bottom, 16)
    }

    private func header(_ detail: ArtistDetail) -> some View {
        VStack(spacing: 12) {
            ArtistArtwork(thumbnails: detail.thumbnails, size: 168)

            Text(detail.name)
                .font(WaveFonts.title(24))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let subscribers = detail.subscribers {
                Text(subscribers)
                    .font(WaveFonts.body(14))
                    .foregroundStyle(WaveColors.secondaryLabel)
            }

            HStack(spacing: 12) {
                Button(action: {
                    player.isShuffleEnabled = true
                    player.playAll(detail.topSongs.shuffled(), startingAt: 0)
                }) {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(WaveFonts.headline(15))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(WaveColors.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(detail.topSongs.isEmpty)

                Button(action: { isFollowing.toggle() }) {
                    Label(
                        isFollowing ? "Following" : "Follow",
                        systemImage: isFollowing ? "checkmark" : "plus"
                    )
                    .font(WaveFonts.headline(15))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        isFollowing ? WaveColors.accent.opacity(0.15) : Color(.secondarySystemBackground),
                        in: Capsule()
                    )
                    .foregroundStyle(isFollowing ? WaveColors.accent : WaveColors.label)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func topSongsSection(_ detail: ArtistDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top songs")
                .font(WaveFonts.headline(18))
                .padding(.horizontal)
            ForEach(Array(detail.topSongs.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, index: index + 1) {
                    player.playAll(detail.topSongs, startingAt: index)
                }
                .padding(.horizontal)
                Divider()
                    .padding(.leading, 72)
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            detail = try await innerTube.artist(id: id)
        } catch {
            errorMessage = "Something went wrong loading this."
        }
        isLoading = false
    }
}
