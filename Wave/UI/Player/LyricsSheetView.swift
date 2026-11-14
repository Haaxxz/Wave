import SwiftUI

// MARK: - Lyrics sheet

/// Synced lyrics for the currently playing track. The active line is
/// highlighted and auto-scrolled into view as playback advances. Falls
/// back to plain text when no synced lyrics exist. The Share button opens
/// the lyrics share screen.
struct LyricsSheetView: View {
    var onShare: ((Track, Lyrics) -> Void)? = nil

    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var currentLineIndex: Int? = nil

    var body: some View {
        NavigationStack {
            Group {
                if let track = player.currentTrack {
                    if let lyrics = player.currentLyrics {
                        lyricsContent(track: track, lyrics: lyrics)
                    } else {
                        loadingState
                    }
                } else {
                    Text("Nothing playing")
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
            }
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let track = player.currentTrack, let lyrics = player.currentLyrics {
                        Button("Share") {
                            dismiss()
                            onShare?(track, lyrics)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func lyricsContent(track: Track, lyrics: Lyrics) -> some View {
        if let synced = lyrics.synced, !synced.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(synced.enumerated()), id: \.offset) { index, line in
                            Text(line.text)
                                .id(index)
                                .font(index == currentLineIndex ? WaveFonts.headline(18) : WaveFonts.body(17))
                                .foregroundStyle(
                                    index == currentLineIndex ? WaveColors.label : WaveColors.secondaryLabel
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .onAppear { updateCurrentLine(scrollTo: proxy) }
                .onChange(of: player.positionSeconds) { _, _ in
                    updateCurrentLine(scrollTo: proxy)
                }
                .onChange(of: currentLineIndex) { _, newIndex in
                    if let newIndex {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }
        } else if let plainText = lyrics.plainText, !plainText.isEmpty {
            ScrollView {
                Text(plainText)
                    .font(WaveFonts.body(17))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 36))
                    .foregroundStyle(WaveColors.secondaryLabel)
                Text("No lyrics for this song")
                    .font(WaveFonts.headline())
                Text("Source: \(lyrics.source)")
                    .font(WaveFonts.body(13))
                    .foregroundStyle(WaveColors.secondaryLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Loading lyrics…")
                .font(WaveFonts.body(14))
                .foregroundStyle(WaveColors.secondaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Current line tracking

    private func updateCurrentLine(scrollTo proxy: ScrollViewProxy) {
        guard let synced = player.currentLyrics?.synced, !synced.isEmpty else { return }
        let positionMs = Int(player.positionSeconds * 1000)
        let index = synced.lastIndex { $0.startMs <= positionMs }
        guard index != currentLineIndex else { return }
        currentLineIndex = index
        if let index {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }
}
