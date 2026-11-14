import SwiftUI

/// Listening statistics.
///
/// Play history comes from the library store (last 200 plays, recorded by
/// the player on every track start). Play counts on liked songs come from
/// the tracks themselves when the service filled them in; the library
/// lengths are plain sums of track lengths, labelled as estimates.
struct StatsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(LibraryStoreImpl.self) private var library
    @Environment(Player.self) private var player

    @State private var friendUsername = ""

    /// Liked songs ranked by play count (unknown counts sort as zero).
    private var topTracks: [Track] {
        library.likedSongs.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
    }

    /// Artists ranked by how many liked songs they have.
    private var topArtists: [(artist: ArtistRef, count: Int)] {
        var counts: [String: (ArtistRef, Int)] = [:]
        for track in library.likedSongs {
            for artist in track.artists {
                let current = counts[artist.id]?.1 ?? 0
                counts[artist.id] = (artist, current + 1)
            }
        }
        return counts.values.sorted { $0.1 > $1.1 }
    }

    /// Rough total listening time: the summed length of every liked song.
    /// It is an estimate of the library's length, not measured play time.
    private var estimatedLibraryLength: TimeInterval {
        TimeInterval(library.likedSongs.compactMap(\.durationSeconds).reduce(0, +))
    }

    private var downloadedLength: TimeInterval {
        TimeInterval(library.downloadedTracks.compactMap { $0.track.durationSeconds }.reduce(0, +))
    }

    var body: some View {
        List {
            Section {
                statRow(label: "Liked songs", value: "\(library.likedSongs.count)")
                statRow(label: "Playlists", value: "\(library.playlists.count)")
                statRow(label: "Downloaded tracks", value: "\(library.downloadedTracks.count)")
                statRow(label: "Liked songs length (estimate)", value: formattedDuration(estimatedLibraryLength))
                statRow(label: "Downloaded length (estimate)", value: formattedDuration(downloadedLength))
            } header: {
                Text("Your library")
            } footer: {
                Text("Listening time is estimated from track lengths in your library.")
            }

            if !library.recentPlayed.isEmpty {
                Section("Recently played") {
                    ForEach(library.recentPlayed.prefix(10)) { track in
                        TrackRow(track: track)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(track) }
                    }
                }
            }

            if !topTracks.isEmpty {
                Section("Top tracks") {
                    ForEach(topTracks.prefix(10)) { track in
                        TrackRow(track: track)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(track) }
                    }
                }
            }

            if !topArtists.isEmpty {
                Section("Top artists") {
                    ForEach(topArtists.prefix(10), id: \.artist.id) { entry in
                        HStack {
                            ArtistRow(artist: entry.artist)
                            Spacer()
                            Text("\(entry.count) liked")
                                .font(.footnote)
                                .foregroundStyle(WaveColors.secondaryLabel)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            router.navigate(.artist(id: entry.artist.id), in: router.selectedTab)
                        }
                    }
                }
            }

            if LastFmService.shared.isConfigured {
                friendsSection
            }
        }
        .navigationTitle("Stats")
    }

    // MARK: - Friends (Last.fm only)

    /// Friend profiles come from Last.fm. There is no friends list API in
    /// this build, so the section is a lookup: type a Last.fm username and
    /// open that friend's profile. It only appears when Last.fm is linked.
    private var friendsSection: some View {
        Section {
            HStack {
                TextField("Last.fm username", text: $friendUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Open") {
                    let username = friendUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !username.isEmpty else { return }
                    router.navigate(.friendProfile(userId: username), in: router.selectedTab)
                }
                .disabled(friendUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Friends")
        } footer: {
            Text("Friend profiles are powered by Last.fm. Enter a friend's Last.fm username to see their profile.")
        }
    }

    // MARK: - Helpers

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(WaveColors.secondaryLabel)
        }
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
