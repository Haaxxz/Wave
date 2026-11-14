import SwiftUI

// MARK: - Album card

/// A vertical album card for horizontal rows and grids: square artwork,
/// title and an optional subtitle line (year or artist names).
struct AlbumCard: View {
    var album: AlbumRef
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(thumbnails: album.thumbnails, size: 140, cornerRadius: 10)
            Text(album.title)
                .font(WaveFonts.body(14))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 140, alignment: .leading)
            if let subtitle {
                Text(subtitle)
                    .font(WaveFonts.body(12))
                    .foregroundStyle(WaveColors.secondaryLabel)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
            }
        }
    }
}

/// A compact album row for vertical lists.
struct AlbumRow: View {
    var album: AlbumRef
    var subtitle: String? = nil

    var body: some View {
        NavigationLink(value: Route.album(id: album.id)) {
            HStack(spacing: 12) {
                ArtworkView(thumbnails: album.thumbnails, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(WaveFonts.body())
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(WaveFonts.body(13))
                            .foregroundStyle(WaveColors.secondaryLabel)
                            .lineLimit(1)
                    } else {
                        Text("Album")
                            .font(WaveFonts.body(13))
                            .foregroundStyle(WaveColors.secondaryLabel)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WaveColors.secondaryLabel)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
