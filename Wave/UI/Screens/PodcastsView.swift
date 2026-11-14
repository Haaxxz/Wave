import SwiftUI

/// Podcasts: the podcast shelf from the home feed. The feed has no
/// podcast-specific item type, so the shelf is the feed sections whose
/// title mentions podcasts. When the feed returns no podcast section,
/// the screen says so honestly instead of inventing a catalogue.
struct PodcastsView: View {
    @Environment(InnerTubeClient.self) private var innerTube

    @State private var sections: [FeedSection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading podcasts…")
            } else if let errorMessage {
                ErrorStateView(message: errorMessage, onRetry: { Task { await load() } })
            } else if sections.isEmpty {
                ContentUnavailableView(
                    "No podcasts here yet",
                    systemImage: "podcast",
                    description: Text("YouTube Music did not return a podcast shelf in the home feed. Pull to try again, or search for a show by name.")
                )
            } else {
                List(sections) { section in
                    SectionRow(section: section)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Podcasts")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let feed = try await innerTube.home()
            sections = feed.filter { section in
                section.title.localizedCaseInsensitiveContains("podcast")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
