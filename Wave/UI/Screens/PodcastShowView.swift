import SwiftUI

/// A podcast show. Podcast shows are playlist-shaped on YouTube Music,
/// so the detail loads through `InnerTubeClient.playlist(id:)` and the
/// episodes are the playlist's tracks. Tapping an episode plays it.
struct PodcastShowView: View {
    var id: String

    @Environment(InnerTubeClient.self) private var innerTube
    @Environment(Player.self) private var player

    @State private var show: Playlist?
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(id: String) {
        self.id = id
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading show…")
            } else if let errorMessage {
                ErrorStateView(message: errorMessage, onRetry: { Task { await load() } })
            } else if let show {
                showContent(show: show)
            } else {
                ContentUnavailableView(
                    "Show not found",
                    systemImage: "podcast",
                    description: Text("This podcast show could not be loaded.")
                )
            }
        }
        .navigationTitle(show?.title ?? "Podcast")
        .task { await load() }
    }

    private func showContent(show: Playlist) -> some View {
        List {
            Section {
                HStack(spacing: 16) {
                    ArtworkView(thumbnails: show.thumbnails, size: 96, cornerRadius: 12)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(show.title)
                            .font(WaveFonts.title(20))
                            .lineLimit(3)
                        if let author = show.author {
                            Text(author)
                                .foregroundStyle(WaveColors.secondaryLabel)
                        }
                        Text("\(show.tracks.count) episodes")
                            .font(.footnote)
                            .foregroundStyle(WaveColors.secondaryLabel)
                    }
                }
                .padding(.vertical, 4)
                if let description = show.description, !description.isEmpty {
                    Text(description)
                        .font(WaveFonts.body())
                }
            }

            Section("Episodes") {
                if show.tracks.isEmpty {
                    Text("This show has no episodes listed.")
                        .foregroundStyle(WaveColors.secondaryLabel)
                } else {
                    ForEach(show.tracks) { episode in
                        TrackRow(track: episode)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(episode) }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    player.addToQueue(episode)
                                } label: {
                                    Label("Queue", systemImage: "text.badge.plus")
                                }
                                .tint(.blue)
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            show = try await innerTube.playlist(id: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
