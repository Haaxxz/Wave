import SwiftUI

// MARK: - Theme
//
// Colours are semantic where possible so dark mode just works. The accent
// comes from the AccentColor asset. Liquid Glass is iOS 26 only — guarded.

enum WaveColors {
    static let accent = Color("AccentColor")
    static let background = Color(.systemBackground)
    static let secondaryBackground = Color(.secondarySystemBackground)
    static let groupedBackground = Color(.systemGroupedBackground)
    static let label = Color(.label)
    static let secondaryLabel = Color(.secondaryLabel)
    static let separator = Color(.separator)

    /// Fallback artwork gradient when a track has no cover art.
    static let artworkPlaceholder = LinearGradient(
        colors: [Color(red: 0.12, green: 0.16, blue: 0.18), Color(red: 0.05, green: 0.07, blue: 0.08)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

enum WaveFonts {
    static func title(_ size: CGFloat = 22) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    static func headline(_ size: CGFloat = 17) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    static func body(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }
}

extension View {
    /// The app's glass surface: real Liquid Glass on iOS 26, a thin material
    /// below. The deployment target is iOS 17, so the iOS 26 branch is
    /// guarded at runtime and only compiles because the iOS 26 SDK is present.
    @ViewBuilder
    func waveGlassBackground(cornerRadius: CGFloat = 20) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// The app's glass button style for the player controls.
    @ViewBuilder
    func waveGlassButton(cornerRadius: CGFloat = 999) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Square artwork with a loading state and a music-note placeholder.
struct ArtworkView: View {
    var thumbnails: [Thumbnail]
    var size: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let url = Thumbnail.best(in: thumbnails, preferWidth: Int(size * 2))?.url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        placeholder
                            .overlay { ProgressView().tint(.white) }
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        ZStack {
            WaveColors.artworkPlaceholder
            Image(systemName: "music.note")
                .foregroundStyle(.white.opacity(0.7))
                .font(.system(size: size * 0.35))
        }
    }
}

/// A small rounded chip, used for genres, moods and filter tags.
struct WaveChip: View {
    var title: String
    var isSelected: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(WaveFonts.body(14))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isSelected ? WaveColors.accent : Color(.secondarySystemBackground),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? .white : WaveColors.label)
        }
        .buttonStyle(.plain)
    }
}
