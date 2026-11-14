import SwiftUI

// MARK: - Mini player

/// The compact player pinned above the tab bar. Shows artwork, title and
/// artist, a play/pause button and a progress bar on a glass surface.
/// Tapping anywhere else opens the full player (`onTap`).
struct MiniPlayerView: View {
    var onTap: () -> Void

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
    }

    @Environment(Player.self) private var player

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottom) {
                HStack(spacing: 12) {
                    if let track = player.currentTrack {
                        ArtworkView(thumbnails: track.thumbnails, size: 44, cornerRadius: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(WaveFonts.body(14))
                                .lineLimit(1)
                            Text(track.artistNames)
                                .font(WaveFonts.body(12))
                                .foregroundStyle(WaveColors.secondaryLabel)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Button(action: { player.togglePlayPause() }) {
                        Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(WaveColors.label)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)

                progressBar
            }
        }
        .buttonStyle(.plain)
        .waveGlassBackground(cornerRadius: 16)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.separator))
                    .frame(height: 3)
                Capsule()
                    .fill(WaveColors.accent)
                    .frame(
                        width: geometry.size.width * progressFraction,
                        height: 3
                    )
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 12)
    }

    private var progressFraction: Double {
        guard player.durationSeconds > 0 else { return 0 }
        return min(max(player.positionSeconds / player.durationSeconds, 0), 1)
    }
}
