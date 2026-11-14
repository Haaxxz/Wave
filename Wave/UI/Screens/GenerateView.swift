import SwiftUI

/// Local playlist generator: pick a mood and a seed song from your liked
/// songs, and Wave builds a mix from YouTube Music's radio for that seed
/// (`InnerTubeClient.next`). The mood ranks matching tracks first — the
/// radio itself is seed-based, so the mood shapes the ordering and the
/// playlist name, not the underlying recommendations.
struct GenerateView: View {
    @Environment(InnerTubeClient.self) private var innerTube
    @Environment(LibraryStoreImpl.self) private var library
    @Environment(Player.self) private var player

    private enum Mood: String, CaseIterable {
        case chill = "Chill"
        case focus = "Focus"
        case workout = "Workout"
        case party = "Party"
        case sad = "Sad"
        case happy = "Happy"

        /// Words that suggest a track fits the mood. Tracks matching any
        /// of these rank first in the generated list.
        var keywords: [String] {
            switch self {
            case .chill: return ["chill", "lofi", "acoustic", "soft", "calm", "slow"]
            case .focus: return ["focus", "ambient", "instrumental", "piano", "study"]
            case .workout: return ["workout", "gym", "energy", "pump", "fast", "beat"]
            case .party: return ["party", "dance", "club", "remix", "electro"]
            case .sad: return ["sad", "heartbreak", "lonely", "blue", "tears"]
            case .happy: return ["happy", "sunny", "good vibes", "feel good", "summer"]
            }
        }
    }

    @State private var selectedMood: Mood = .chill
    @State private var selectedSeed: Track?
    @State private var generated: [Track] = []
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var saveNotice: String?

    var body: some View {
        Form {
            Section("Mood") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 8) {
                    ForEach(Mood.allCases, id: \.self) { mood in
                        WaveChip(title: mood.rawValue, isSelected: selectedMood == mood) {
                            selectedMood = mood
                        }
                    }
                }
            }

            Section("Seed song") {
                if library.likedSongs.isEmpty {
                    Text("Like some songs first — the generator seeds the mix from a song you love.")
                        .font(.footnote)
                        .foregroundStyle(WaveColors.secondaryLabel)
                } else {
                    Picker("Seed", selection: $selectedSeed) {
                        Text("Pick a song").tag(nil as Track?)
                        ForEach(library.likedSongs) { track in
                            Text(track.title).tag(track as Track?)
                        }
                    }
                }
            }

            Section {
                Button("Generate playlist") {
                    Task { await generate() }
                }
                .disabled(selectedSeed == nil || isGenerating)
                if isGenerating {
                    ProgressView("Building your mix…")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if !generated.isEmpty {
                Section("\(selectedMood.rawValue) mix") {
                    ForEach(generated) { track in
                        TrackRow(track: track)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(track) }
                    }
                }

                Section {
                    Button("Save as playlist") {
                        Task { await save() }
                    }
                    if let saveNotice {
                        Text(saveNotice)
                            .font(.footnote)
                            .foregroundStyle(WaveColors.secondaryLabel)
                    }
                }
            }
        }
        .navigationTitle("Generate")
    }

    // MARK: - Generation

    private func generate() async {
        guard let seed = selectedSeed else { return }
        isGenerating = true
        errorMessage = nil
        saveNotice = nil
        defer { isGenerating = false }
        do {
            let radio = try await innerTube.next(videoId: seed.id, playlistId: nil)
            generated = rank(radio, for: selectedMood)
            if generated.isEmpty {
                errorMessage = "YouTube Music returned no radio tracks for this seed. Try another seed song."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Matching tracks first, then the rest in radio order, so the list
    /// is never empty just because the mood words did not match.
    private func rank(_ tracks: [Track], for mood: Mood) -> [Track] {
        let keywords = mood.keywords
        let matches = tracks.filter { track in
            let haystack = (track.title + " " + track.artistNames).lowercased()
            return keywords.contains { haystack.contains($0) }
        }
        let rest = tracks.filter { track in !matches.contains(track) }
        return matches + rest
    }

    private func save() async {
        guard let seed = selectedSeed, !generated.isEmpty else { return }
        let title = "\(selectedMood.rawValue) mix — \(seed.title)"
        await library.createPlaylist(title: title)
        guard let playlist = library.playlists.first(where: { $0.title == title }) else {
            saveNotice = "The playlist was created, but it could not be found to add tracks to."
            return
        }
        for track in generated {
            await library.addToPlaylist(track, playlistId: playlist.id)
        }
        saveNotice = "Saved “\(title)” with \(generated.count) tracks to your library."
    }
}
