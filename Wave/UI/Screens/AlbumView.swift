import SwiftUI

// MARK: - Album detail

/// Album page: header with artwork, title, artists and year, Play / Shuffle
/// / Download-all / Like actions, then the track list. Tapping a track
/// plays the album from that track.
struct AlbumView: View {
    var id: String

    init(id: String) {
        self.id = id
    }

    @Environment(InnerTubeClient.self) private var innerTube
    @Environment(Player.self) private var player
    @Environment(LibraryStoreImpl.self) private var library

    @State private var album: Album? = nil
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var allLiked: Bool {
        guard let album, !album.tracks.isEmpty else { return false }
        return album.tracks.allSatisfy { library.likedSongs.contains($0) }
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
            } else if let album {
                albumContent(album)
            } else {
                ErrorStateView(message: "This album could not be found.") {
                    Task { await load() }
                }
            }
        }
        .navigationTitle(album?.title ?? "Album")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Content

    private func albumContent(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            header(album)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            if let description = album.description, !description.isEmpty {
                Text(description)
                    .font(WaveFonts.body(14))
                    .foregroundStyle(WaveColors.secondaryLabel)
                    .padding(.horizontal)
            }

            trackList(album)
        }
        .padding(.bottom, 16)
    }

    private func header(_ album: Album) -> some View {
        VStack(spacing: 12) {
            ArtworkView(thumbnails: album.thumbnails, size: 200, cornerRadius: 12)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            Text(album.title)
                .font(WaveFonts.title(22))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 4) {
                ForEach(Array(album.artists.enumerated()), id: \.element.id) { index, artist in
                    if index > 0 {
                        Text("·").foregroundStyle(WaveColors.secondaryLabel)
                    }
                    NavigationLink(value: Route.artist(id: artist.id)) {
                        Text(artist.name)
                            .font(WaveFonts.body(14))
                            .foregroundStyle(WaveColors.accent)
                    }
                    .buttonStyle(.plain)
                }
                if let year = album.year {
                    Text("· \(year)")
                        .font(WaveFonts.body(14))
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
            }

            HStack(spacing: 12) {
                Button(action: { player.playAll(album.tracks, startingAt: 0) }) {
                    Label("Play", systemImage: "play.fill")
                        .font(WaveFonts.headline(15))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(WaveColors.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(album.tracks.isEmpty)

                Button(action: {
                    player.isShuffleEnabled = true
                    player.playAll(album.tracks.shuffled(), startingAt: 0)
                }) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(11)
                        .background(Color(.secondarySystemBackground), in: Circle())
                        .foregroundStyle(WaveColors.label)
                }
                .buttonStyle(.plain)
                .disabled(album.tracks.isEmpty)

                Button(action: {
                    Task {
                        for track in album.tracks {
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
                .disabled(album.tracks.isEmpty)

                Button(action: { toggleLikeAll(album) }) {
                    Image(systemName: allLiked ? "heart.fill" : "heart")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(11)
                        .background(Color(.secondarySystemBackground), in: Circle())
                        .foregroundStyle(allLiked ? WaveColors.accent : WaveColors.label)
                }
                .buttonStyle(.plain)
                .disabled(album.tracks.isEmpty)
            }
        }
    }

    private func trackList(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(album.tracks.count) songs")
                .font(WaveFonts.headline(18))
                .padding(.horizontal)
            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, index: index + 1) {
                    player.playAll(album.tracks, startingAt: index)
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
    private func toggleLikeAll(_ album: Album) {
        let targetLiked = !allLiked
        Task {
            for track in album.tracks {
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
            album = try await innerTube.album(id: id)
        } catch {
            errorMessage = "Something went wrong loading this."
        }
        isLoading = false
    }
}
