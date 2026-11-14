import SwiftUI

// MARK: - Genres

/// A grid of genre and mood tiles. Tapping a tile shows that browse
/// section in place as a vertical list of its items.
struct GenresView: View {
    @Environment(InnerTubeClient.self) private var innerTube

    @State private var sections: [FeedSection] = []
    @State private var selectedSection: FeedSection? = nil
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        Group {
            if isLoading {
                LoadingShimmerView(rows: 6)
            } else if let errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task { await load() }
                }
            } else if let selectedSection {
                sectionDetail(selectedSection)
            } else if sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(sections) { section in
                            GenreTile(title: section.title, itemCount: section.items.count)
                                .onTapGesture { selectedSection = section }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(selectedSection == nil ? "Genres" : selectedSection?.title ?? "Genres")
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if selectedSection != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { selectedSection = nil }) {
                        Label("All genres", systemImage: "chevron.left")
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private func sectionDetail(_ section: FeedSection) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(section.items, id: \.self) { item in
                    feedItemRow(item)
                        .padding(.horizontal)
                    Divider()
                        .padding(.leading, 60)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func feedItemRow(_ item: FeedItem) -> some View {
        switch item {
        case .track(let track):
            TrackRow(track: track)
        case .album(let album):
            AlbumRow(album: album)
        case .artist(let artist):
            ArtistRow(artist: artist)
        case .playlist(let playlist):
            PlaylistRow(playlist: playlist)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 36))
                .foregroundStyle(WaveColors.secondaryLabel)
            Text("No genres right now")
                .font(WaveFonts.headline())
            Text("Pull down to refresh and try again.")
                .font(WaveFonts.body(14))
                .foregroundStyle(WaveColors.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            sections = try await innerTube.genres()
        } catch {
            errorMessage = "Something went wrong loading this."
        }
        isLoading = false
    }
}

// MARK: - Genre tile

private struct GenreTile: View {
    var title: String
    var itemCount: Int

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            tileGradient
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(WaveFonts.headline(17))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text("\(itemCount) items")
                    .font(WaveFonts.body(12))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(14)
        }
        .frame(height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// A deterministic gradient per title so tiles keep stable colours.
    private var tileGradient: LinearGradient {
        let hues: [Double] = [0.48, 0.58, 0.75, 0.05, 0.92, 0.35]
        let hash = abs(title.hashValue)
        let hue = hues[hash % hues.count]
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.65, brightness: 0.75),
                Color(hue: hue, saturation: 0.7, brightness: 0.4),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
