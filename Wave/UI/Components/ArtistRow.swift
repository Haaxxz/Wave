import SwiftUI

// MARK: - Artist row

/// A list row for an artist: circular artwork, name and a chevron.
/// Tapping navigates to the artist detail screen.
struct ArtistRow: View {
    var artist: ArtistRef

    var body: some View {
        NavigationLink(value: Route.artist(id: artist.id)) {
            HStack(spacing: 12) {
                ArtistArtwork(thumbnails: artist.thumbnails, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name)
                        .font(WaveFonts.body())
                        .lineLimit(1)
                    Text("Artist")
                        .font(WaveFonts.body(13))
                        .foregroundStyle(WaveColors.secondaryLabel)
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

/// Circular artist artwork with a placeholder fallback.
struct ArtistArtwork: View {
    var thumbnails: [Thumbnail]
    var size: CGFloat

    var body: some View {
        Group {
            if let url = Thumbnail.best(in: thumbnails, preferWidth: Int(size * 2))?.url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        placeholder.overlay { ProgressView().tint(.white) }
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ZStack {
            WaveColors.artworkPlaceholder
            Image(systemName: "person.fill")
                .foregroundStyle(.white.opacity(0.7))
                .font(.system(size: size * 0.35))
        }
    }
}

// MARK: - Artist circle card (for horizontal rows)

/// A circular artist card used inside horizontal section rows.
struct ArtistCircleCard: View {
    var artist: ArtistRef

    var body: some View {
        VStack(spacing: 8) {
            ArtistArtwork(thumbnails: artist.thumbnails, size: 120)
            Text(artist.name)
                .font(WaveFonts.body(14))
                .lineLimit(1)
                .frame(width: 120)
        }
    }
}
