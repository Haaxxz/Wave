import SwiftUI

/// Turns a track and its lyrics into a shareable quote card: artwork,
/// title, artist and a few lyric lines on a dark card. The card is
/// rendered to an image with `ImageRenderer` and shared through a
/// `ShareLink` — nothing is uploaded, the image is made on the device.
struct LyricsShareView: View {
    var track: Track
    var lyrics: Lyrics

    @State private var renderedImage: UIImage?

    init(track: Track, lyrics: Lyrics) {
        self.track = track
        self.lyrics = lyrics
    }

    /// The lines shown on the card: synced lines first, otherwise the
    /// first lines of the plain text. At most four, so the card stays
    /// readable.
    private var cardLines: [String] {
        if let synced = lyrics.synced, !synced.isEmpty {
            return Array(synced.prefix(4).map(\.text))
        }
        guard let plainText = lyrics.plainText else { return [] }
        return Array(plainText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(4))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                QuoteCardView(track: track, lines: cardLines)

                if let renderedImage {
                    ShareLink(
                        item: Image(uiImage: renderedImage),
                        preview: SharePreview(track.title, image: Image(uiImage: renderedImage))
                    ) {
                        Label("Share image", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    ProgressView("Rendering card…")
                }

                Text("Lyrics via \(lyrics.source.isEmpty ? "Wave" : lyrics.source).")
                    .font(.footnote)
                    .foregroundStyle(WaveColors.secondaryLabel)
            }
            .padding()
        }
        .navigationTitle("Share lyrics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            render()
        }
    }

    private func render() {
        let renderer = ImageRenderer(content: QuoteCardView(track: track, lines: cardLines))
        renderer.scale = 3
        renderedImage = renderer.uiImage
    }

    // MARK: - The card itself

    private struct QuoteCardView: View {
        var track: Track
        var lines: [String]

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ArtworkView(thumbnails: track.thumbnails, size: 64, cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(WaveFonts.headline(17))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(track.artistNames)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }

                if lines.isEmpty {
                    Text("No lyrics to share for this track.")
                        .font(WaveFonts.body(17))
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(lines, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 18, weight: .medium, design: .serif))
                                .foregroundStyle(.white)
                        }
                    }
                }

                Spacer(minLength: 8)

                HStack {
                    Text("Wave")
                        .font(.footnote)
                        .bold()
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Image(systemName: "waveform")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(24)
            .frame(width: 360, height: 480, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.05, green: 0.12, blue: 0.14), Color(red: 0.02, green: 0.04, blue: 0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
    }
}
