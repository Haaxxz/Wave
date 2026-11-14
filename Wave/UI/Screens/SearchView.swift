import SwiftUI

// MARK: - Search

/// Search with live suggestions, recent searches and grouped results
/// (Songs, Albums, Artists, Playlists, Videos).
struct SearchView: View {
    @Environment(InnerTubeClient.self) private var innerTube
    @Environment(Player.self) private var player
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismissSearch) private var dismissSearch

    @State private var query = ""
    @State private var suggestions: [String] = []
    @State private var results: SearchResults? = nil
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var suggestionTask: Task<Void, Never>? = nil

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else if let errorMessage {
                Section {
                    ErrorStateView(message: errorMessage) {
                        runSearch(query)
                    }
                }
            } else if hasSearched {
                resultsSections
            } else if query.isEmpty {
                recentSearchesSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Search")
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Songs, albums, artists"
        )
        .searchSuggestions {
            ForEach(suggestions, id: \.self) { suggestion in
                Button(action: { runSearch(suggestion) }) {
                    Label(suggestion, systemImage: "magnifyingglass")
                }
                .searchCompletion(suggestion)
            }
        }
        .onChange(of: query) { _, newValue in
            scheduleSuggestions(for: newValue)
        }
        .onSubmit(of: .search) {
            runSearch(query)
        }
    }

    // MARK: - List sections

    @ViewBuilder
    private var resultsSections: some View {
        if let results {
            if results.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(WaveColors.secondaryLabel)
                        Text("No results for “\(query)”")
                            .font(WaveFonts.headline())
                        Text("Check the spelling or try a different search.")
                            .font(WaveFonts.body(14))
                            .foregroundStyle(WaveColors.secondaryLabel)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            } else {
                songsSection(results)
                albumsSection(results)
                artistsSection(results)
                playlistsSection(results)
                videosSection(results)
            }
        } else {
            Section {
                Text("No results")
                    .foregroundStyle(WaveColors.secondaryLabel)
            }
        }
    }

    @ViewBuilder
    private func songsSection(_ results: SearchResults) -> some View {
        if !results.songs.isEmpty {
            Section("Songs") {
                ForEach(Array(results.songs.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track, showArtwork: true) {
                        player.playAll(results.songs, startingAt: index)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func albumsSection(_ results: SearchResults) -> some View {
        if !results.albums.isEmpty {
            Section("Albums") {
                ForEach(results.albums) { album in
                    AlbumRow(album: album)
                }
            }
        }
    }

    @ViewBuilder
    private func artistsSection(_ results: SearchResults) -> some View {
        if !results.artists.isEmpty {
            Section("Artists") {
                ForEach(results.artists) { artist in
                    ArtistRow(artist: artist)
                }
            }
        }
    }

    @ViewBuilder
    private func playlistsSection(_ results: SearchResults) -> some View {
        if !results.playlists.isEmpty {
            Section("Playlists") {
                ForEach(results.playlists) { playlist in
                    PlaylistRow(playlist: playlist)
                }
            }
        }
    }

    @ViewBuilder
    private func videosSection(_ results: SearchResults) -> some View {
        if !results.videos.isEmpty {
            Section("Videos") {
                ForEach(Array(results.videos.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track, showArtwork: true) {
                        player.playAll(results.videos, startingAt: index)
                    }
                }
            }
        }
    }

    private var recentSearchesSection: some View {
        Section("Recent searches") {
            if settings.searchHistory.isEmpty {
                Text("Your recent searches will show up here.")
                    .foregroundStyle(WaveColors.secondaryLabel)
            } else {
                ForEach(settings.searchHistory, id: \.self) { pastQuery in
                    Button(action: { runSearch(pastQuery) }) {
                        HStack {
                            Image(systemName: "clock")
                                .foregroundStyle(WaveColors.secondaryLabel)
                            Text(pastQuery)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    settings.searchHistory.remove(atOffsets: offsets)
                }

                Button("Clear history", role: .destructive) {
                    settings.clearSearchHistory()
                }
            }
        }
    }

    // MARK: - Search work

    private func scheduleSuggestions(for text: String) {
        suggestionTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            return
        }
        suggestionTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let fetched = try await innerTube.suggestions(query: trimmed)
                guard !Task.isCancelled else { return }
                suggestions = fetched
            } catch {
                // Suggestions are best-effort; a failure just leaves the list empty.
                suggestions = []
            }
        }
    }

    private func runSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        query = trimmed
        suggestions = []
        dismissSearch()
        settings.addSearchHistory(trimmed)
        Task { await performSearch(trimmed) }
    }

    private func performSearch(_ text: String) async {
        isLoading = true
        errorMessage = nil
        hasSearched = true
        do {
            results = try await innerTube.search(query: text)
        } catch {
            results = nil
            errorMessage = "Something went wrong loading this."
        }
        isLoading = false
    }
}
