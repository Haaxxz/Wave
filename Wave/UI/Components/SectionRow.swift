import SwiftUI

// MARK: - Feed section row

/// A titled horizontal scrolling row of cards for one `FeedSection`, as used
/// on the home feed, Discover and charts. Tracks play on tap; albums,
/// artists and playlists navigate to their detail screens.
struct SectionRow: View {
    var section: FeedSection

    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title)
                    .font(WaveFonts.headline(18))
                Spacer()
                if section.browseId != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(section.items, id: \.self) { item in
                        feedItemView(item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func feedItemView(_ item: FeedItem) -> some View {
        switch item {
        case .track(let track):
            TrackCard(track: track)
        case .album(let album):
            NavigationLink(value: Route.album(id: album.id)) {
                AlbumCard(album: album)
            }
            .buttonStyle(.plain)
        case .artist(let artist):
            NavigationLink(value: Route.artist(id: artist.id)) {
                ArtistCircleCard(artist: artist)
            }
            .buttonStyle(.plain)
        case .playlist(let playlist):
            NavigationLink(value: Route.playlist(id: playlist.id)) {
                PlaylistCard(playlist: playlist)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Vertical track card (for horizontal rows)

private struct TrackCard: View {
    var track: Track

    @Environment(Player.self) private var player

    var body: some View {
        Button(action: { player.play(track) }) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    ArtworkView(thumbnails: track.thumbnails, size: 140, cornerRadius: 10)
                    if track.isVideo {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                            .offset(x: -4, y: -4)
                    }
                }
                Text(track.title)
                    .font(WaveFonts.body(14))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 140, alignment: .leading)
                Text(track.artistNames)
                    .font(WaveFonts.body(12))
                    .foregroundStyle(WaveColors.secondaryLabel)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}
