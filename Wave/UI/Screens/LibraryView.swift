import SwiftUI

/// The user's library: liked songs, playlists, downloads and artists.
/// Data comes from `LibraryStoreImpl`; nothing is fetched over the network
/// here — the store owns the persisted library.
struct LibraryView: View {
    @Environment(AppRouter.self) private var router
    @Environment(LibraryStoreImpl.self) private var library
    @Environment(Player.self) private var player

    private enum Segment: String, CaseIterable {
        case liked = "Liked"
        case playlists = "Playlists"
        case downloads = "Downloads"
        case artists = "Artists"
    }

    @State private var segment: Segment = .liked
    @State private var showingCreatePlaylist = false
    @State private var newPlaylistTitle = ""

    /// Artists derived from the liked songs, de-duplicated by id.
    private var artists: [ArtistRef] {
        var seen = Set<String>()
        var result: [ArtistRef] = []
        for track in library.likedSongs {
            for artist in track.artists where seen.insert(artist.id).inserted {
                result.append(artist)
            }
        }
        return result
    }

    var body: some View {
        VStack {
            Picker("Library", selection: $segment) {
                ForEach(Segment.allCases, id: \.self) { segment in
                    Text(segment.rawValue).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            switch segment {
            case .liked:
                likedList
            case .playlists:
                playlistsList
            case .downloads:
                downloadsList
            case .artists:
                artistsList
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.navigate(.settings, in: router.selectedTab)
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .alert("New playlist", isPresented: $showingCreatePlaylist) {
            TextField("Playlist name", text: $newPlaylistTitle)
            Button("Cancel", role: .cancel) { newPlaylistTitle = "" }
            Button("Create") {
                let title = newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                newPlaylistTitle = ""
                Task { await library.createPlaylist(title: title) }
            }
        } message: {
            Text("Give your playlist a name.")
        }
    }

    // MARK: - Liked songs

    private var likedList: some View {
        Group {
            if library.likedSongs.isEmpty {
                ContentUnavailableView(
                    "No liked songs yet",
                    systemImage: "heart",
                    description: Text("Tap the heart on any track to keep it here.")
                )
            } else {
                List {
                    ForEach(library.likedSongs) { track in
                        TrackRow(track: track)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(track) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await library.toggleLike(track) }
                                } label: {
                                    Label("Unlike", systemImage: "heart.slash")
                                }
                                Button {
                                    Task { await library.download(track) }
                                } label: {
                                    Label("Download", systemImage: "arrow.down.circle")
                                }
                                .tint(.blue)
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Playlists

    private var playlistsList: some View {
        List {
            Button {
                showingCreatePlaylist = true
            } label: {
                Label("New playlist", systemImage: "plus")
            }

            ForEach(library.playlists) { playlist in
                PlaylistCard(playlist: PlaylistRef(
                    id: playlist.id,
                    title: playlist.title,
                    author: playlist.author,
                    thumbnails: playlist.thumbnails,
                    trackCount: playlist.tracks.count
                ))
                .contentShape(Rectangle())
                .onTapGesture {
                    router.navigate(.playlist(id: playlist.id), in: router.selectedTab)
                }
                .contextMenu {
                    Button {
                        player.playAll(playlist.tracks, startingAt: 0)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button {
                        for track in playlist.tracks {
                            player.addToQueue(track)
                        }
                    } label: {
                        Label("Add all to queue", systemImage: "text.badge.plus")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Downloads

    private var downloadsList: some View {
        List {
            Button {
                router.navigate(.downloads, in: router.selectedTab)
            } label: {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(WaveColors.accent)
                    VStack(alignment: .leading) {
                        Text("Downloaded songs")
                            .foregroundStyle(WaveColors.label)
                        Text("\(library.downloadedTracks.count) tracks on this device")
                            .font(.footnote)
                            .foregroundStyle(WaveColors.secondaryLabel)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
            }

            ForEach(library.downloadedTracks.prefix(10)) { downloaded in
                TrackRow(track: downloaded.track)
                    .contentShape(Rectangle())
                    .onTapGesture { player.play(downloaded.track) }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Artists

    private var artistsList: some View {
        Group {
            if artists.isEmpty {
                ContentUnavailableView(
                    "No artists yet",
                    systemImage: "person.2",
                    description: Text("Artists from your liked songs will show up here.")
                )
            } else {
                List(artists) { artist in
                    ArtistRow(artist: artist)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            router.navigate(.artist(id: artist.id), in: router.selectedTab)
                        }
                }
                .listStyle(.plain)
            }
        }
    }
}
