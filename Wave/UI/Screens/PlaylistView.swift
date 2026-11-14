import SwiftUI

// MARK: - Playlist detail

/// Playlist page: same shape as the album page (header, Play / Shuffle /
/// Download-all / Like actions, track list) plus the playlist author and
/// description.
struct PlaylistView: View {
    var id: String

    init(id: String) {
        self.id = id
    }

    @Environment(InnerTubeClient.self) private var innerTube
    @Environment(Player.self) private var player
    @Environment(LibraryStoreImpl.self) private var library

    @State private var playlist: Playlist? = nil
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var allLiked: Bool {
        guard let playlist, !playlist.tracks.isEmpty else { return false }
        return playlist.tracks.allSatisfy { library.likedSongs.contains($0) }
    }

    var body: some View {
        ScrollView {
            if isLoading {
                LoadingShimmerView(rows: 8)
                    .padding(.top, 16)
            } else if let errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task { await load() }
                }
            } else if let playlist {
                playlistContent(playlist)
            } else {
                ErrorStateView(message: "This playlist could not be found.") {
                    Task { await load() }
                }
            }
        }
        .navigationTitle(playlist?.title ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Content

    private func playlistContent(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            header(playlist)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            if let description = playlist.description, !description.isEmpty {
                Text(description)
                    .font(WaveFonts.body(14))
                    .foregroundStyle(WaveColors.secondaryLabel)
                    .padding(.horizontal)
            }

            trackList(playlist)
        }
        .padding(.bottom, 16)
    }

    private func header(_ playlist: Playlist) -> some View {
        VStack(spacing: 12) {
            ArtworkView(thumbnails: playlist.thumbnails, size: 200, cornerRadius: 12)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            Text(playlist.title)
                .font(WaveFonts.title(22))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let author = playlist.author, !author.isEmpty {
                Text("By \(author)")
                    .font(WaveFonts.body(14))
                    .foregroundStyle(WaveColors.secondaryLabel)
            }

            HStack(spacing: 12) {
                Button(action: { player.playAll(playlist.tracks, startingAt: 0) }) {
                    Label("Play", systemImage: "play.fill")
                        .font(WaveFonts.headline(15))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(WaveColors.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(playlist.tracks.isEmpty)

                Button(action: {
                    player.isShuffleEnabled = true
                    player.playAll(playlist.tracks.shuffled(), startingAt: 0)
                }) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(11)
                        .background(Color(.secondarySystemBackground), in: Circle())
                        .foregroundStyle(WaveColors.label)
                }
                .buttonStyle(.plain)
                .disabled(playlist.tracks.isEmpty)

                Button(action: {
                    Task {
                        for track in playlist.tracks {
                            await library.download(track)
                        }
                    }
                }) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(11)
                        .background(Color(.secondarySystemBackground), in: Circle())
                        .foregroundStyle(WaveColors.label)
                }
                .buttonStyle(.plain)
                .disabled(playlist.tracks.isEmpty)

                Button(action: { toggleLikeAll(playlist) }) {
                    Image(systemName: allLiked ? "heart.fill" : "heart")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(11)
                        .background(Color(.secondarySystemBackground), in: Circle())
                        .foregroundStyle(allLiked ? WaveColors.accent : WaveColors.label)
                }
                .buttonStyle(.plain)
                .disabled(playlist.tracks.isEmpty)
            }
        }
    }

    private func trackList(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(playlist.tracks.count) songs")
                .font(WaveFonts.headline(18))
                .padding(.horizontal)
            ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, index: index + 1) {
                    player.playAll(playlist.tracks, startingAt: index)
                }
                .padding(.horizontal)
                Divider()
                    .padding(.leading, 72)
            }
        }
    }

    // MARK: - Actions

    /// Likes every track when not all are liked, unlikes every track when
    /// all are liked. Only the tracks that differ from the target change.
    private func toggleLikeAll(_ playlist: Playlist) {
        let targetLiked = !allLiked
        Task {
            for track in playlist.tracks {
                let currentlyLiked = library.likedSongs.contains(track)
                if currentlyLiked != targetLiked {
                    await library.toggleLike(track)
                }
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            playlist = try await innerTube.playlist(id: id)
        } catch {
            errorMessage = "Something went wrong loading this."
        }
        isLoading = false
    }
}
