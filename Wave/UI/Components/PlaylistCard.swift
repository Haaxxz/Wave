import SwiftUI

// MARK: - Playlist card

/// A vertical playlist card for horizontal rows and grids: square artwork
/// with a playlist badge, title and an optional subtitle line (author or
/// track count).
struct PlaylistCard: View {
    var playlist: PlaylistRef

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(thumbnails: playlist.thumbnails, size: 140, cornerRadius: 10)
                Image(systemName: "list.bullet")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .offset(x: -4, y: -4)
            }
            Text(playlist.title)
                .font(WaveFonts.body(14))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 140, alignment: .leading)
            Text(subtitle)
                .font(WaveFonts.body(12))
                .foregroundStyle(WaveColors.secondaryLabel)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let author = playlist.author, !author.isEmpty {
            parts.append(author)
        }
        if let trackCount = playlist.trackCount {
            parts.append("\(trackCount) songs")
        }
        return parts.isEmpty ? "Playlist" : parts.joined(separator: " · ")
    }
}

/// A compact playlist row for vertical lists.
struct PlaylistRow: View {
    var playlist: PlaylistRef

    var body: some View {
        NavigationLink(value: Route.playlist(id: playlist.id)) {
            HStack(spacing: 12) {
                ArtworkView(thumbnails: playlist.thumbnails, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title)
                        .font(WaveFonts.body())
                        .lineLimit(1)
                    Text(playlist.author ?? "Playlist")
                        .font(WaveFonts.body(13))
                        .foregroundStyle(WaveColors.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer()
                if let trackCount = playlist.trackCount {
                    Text("\(trackCount)")
                        .font(WaveFonts.body(13))
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WaveColors.secondaryLabel)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
