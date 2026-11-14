import SwiftUI

// MARK: - Discover

/// Moods, genres and charts. Genre chips select a genre section in place;
/// the "All genres" chip navigates to the full genre grid. Chart sections
/// render as horizontal card rows below.
struct DiscoverView: View {
    @Environment(InnerTubeClient.self) private var innerTube

    @State private var charts: [FeedSection] = []
    @State private var genreSections: [FeedSection] = []
    @State private var selectedGenreIndex: Int? = nil
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isLoading {
                    LoadingShimmerView(rows: 3)
                    LoadingCardRowView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                } else {
                    genreChips

                    if let selectedGenreIndex {
                        SectionRow(section: genreSections[selectedGenreIndex])
                    } else {
                        ForEach(charts) { section in
                            SectionRow(section: section)
                        }
                        if charts.isEmpty && genreSections.isEmpty {
                            emptyState
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("Discover")
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Subviews

    private var genreChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                NavigationLink(value: Route.genres) {
                    Text("All genres")
                        .font(WaveFonts.body(14))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                        .foregroundStyle(WaveColors.label)
                }
                .buttonStyle(.plain)

                ForEach(genreSections.indices, id: \.self) { index in
                    WaveChip(
                        title: genreSections[index].title,
                        isSelected: selectedGenreIndex == index
                    ) {
                        if selectedGenreIndex == index {
                            selectedGenreIndex = nil
                        } else {
                            selectedGenreIndex = index
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.mic")
                .font(.system(size: 36))
                .foregroundStyle(WaveColors.secondaryLabel)
            Text("No charts right now")
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
            async let chartsTask = innerTube.charts(country: "US")
            async let genresTask = innerTube.genres()
            charts = try await chartsTask
            genreSections = try await genresTask
        } catch {
            errorMessage = "Something went wrong loading this."
        }
        isLoading = false
    }
}
