import SwiftUI

// MARK: - Track row

/// A single track in a list: artwork, title, artists, duration, like button
/// and an overflow menu. Tapping the row plays the track (or runs `onPlay`
/// when one is supplied, e.g. to play from an index in a list).
struct TrackRow: View {
    var track: Track
    var index: Int? = nil
    var showArtwork: Bool = true
    var onPlay: (() -> Void)? = nil

    @Environment(Player.self) private var player
    @Environment(LibraryStoreImpl.self) private var library

    @State private var showAddToPlaylist = false

    private var isCurrent: Bool {
        player.currentTrack?.id == track.id
    }

    private var isLiked: Bool {
        library.likedSongs.contains(track)
    }

    private var shareURL: URL? {
        URL(string: "https://music.youtube.com/watch?v=\(track.id)")
    }

    var body: some View {
        Button(action: { onPlay?() ?? player.play(track) }) {
            HStack(spacing: 12) {
                if let index {
                    Text("\(index + 1)")
                        .font(WaveFonts.body(14))
                        .foregroundStyle(WaveColors.secondaryLabel)
                        .frame(width: 24, alignment: .trailing)
                }

                if showArtwork {
                    ZStack(alignment: .bottomTrailing) {
                        ArtworkView(thumbnails: track.thumbnails, size: 48)
                        if track.isVideo {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                                .offset(x: -2, y: -2)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(WaveFonts.body())
                        .foregroundStyle(isCurrent ? WaveColors.accent : WaveColors.label)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if track.explicit {
                            Text("E")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(WaveColors.secondaryLabel)
                        }
                        Text(track.artistNames)
                            .font(WaveFonts.body(13))
                            .foregroundStyle(WaveColors.secondaryLabel)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if isCurrent && player.state == .playing {
                    EqualizerBarsView()
                }

                if let durationSeconds = track.durationSeconds {
                    Text(formatDuration(seconds: durationSeconds))
                        .font(WaveFonts.body(13))
                        .foregroundStyle(WaveColors.secondaryLabel)
                        .monospacedDigit()
                }

                Button(action: { Task { await library.toggleLike(track) } }) {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .foregroundStyle(isLiked ? WaveColors.accent : WaveColors.secondaryLabel)
                }
                .buttonStyle(.plain)

                Menu {
                    Button(action: { player.addToQueue(track) }) {
                        Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button(action: { player.addToQueue(track) }) {
                        Label("Add to queue", systemImage: "text.append")
                    }
                    Button(action: { Task { await player.startRadio(for: track) } }) {
                        Label("Start radio", systemImage: "radio")
                    }
                    Button(action: { showAddToPlaylist = true }) {
                        Label("Add to playlist", systemImage: "text.badge.plus")
                    }
                    Button(action: { Task { await library.download(track) } }) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let artist = track.artists.first {
                        NavigationLink(value: Route.artist(id: artist.id)) {
                            Label("Go to artist", systemImage: "person")
                        }
                    }
                    if let album = track.album {
                        NavigationLink(value: Route.album(id: album.id)) {
                            Label("Go to album", systemImage: "square.stack")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(WaveColors.secondaryLabel)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(track: track)
        }
    }
}

// MARK: - Add to playlist sheet

private struct AddToPlaylistSheet: View {
    var track: Track

    @Environment(LibraryStoreImpl.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var newPlaylistTitle = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New playlist name", text: $newPlaylistTitle)
                        Button("Create") {
                            let title = newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !title.isEmpty else { return }
                            Task {
                                await library.createPlaylist(title: title)
                                newPlaylistTitle = ""
                            }
                        }
                        .disabled(newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("Playlists") {
                    if library.playlists.isEmpty {
                        Text("No playlists yet — create one above.")
                            .foregroundStyle(WaveColors.secondaryLabel)
                    } else {
                        ForEach(library.playlists) { playlist in
                            Button(action: {
                                Task {
                                    await library.addToPlaylist(track, playlistId: playlist.id)
                                    dismiss()
                                }
                            }) {
                                HStack {
                                    Text(playlist.title)
                                    Spacer()
                                    Text("\(playlist.tracks.count) songs")
                                        .font(WaveFonts.body(13))
                                        .foregroundStyle(WaveColors.secondaryLabel)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Animated equaliser bars (playing indicator)

struct EqualizerBarsView: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(WaveColors.accent)
                    .frame(width: 3, height: animating ? [14, 8, 11][index] : [6, 12, 8][index])
                    .animation(
                        .easeInOut(duration: [0.5, 0.7, 0.6][index])
                            .repeatForever(autoreverses: true),
                        value: animating
                    )
            }
        }
        .frame(height: 14)
        .onAppear { animating = true }
    }
}
