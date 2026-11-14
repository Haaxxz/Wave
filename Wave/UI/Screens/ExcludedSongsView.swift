import SwiftUI

/// Songs excluded from recommendations, radio and the home feed.
/// Exclusions are stored as track ids in `SettingsStore.excludedSongIds`.
/// The currently playing track can be added with one tap.
struct ExcludedSongsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(Player.self) private var player

    var body: some View {
        List {
            Section {
                if let current = player.currentTrack {
                    Button {
                        add(current.id)
                    } label: {
                        Label("Exclude currently playing: \(current.title)", systemImage: "eye.slash")
                    }
                    .disabled(settings.excludedSongIds.contains(current.id))
                } else {
                    Text("Nothing is playing right now. Play a track to exclude it from here.")
                        .font(.footnote)
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
            }

            Section("Excluded") {
                if settings.excludedSongIds.isEmpty {
                    Text("No songs excluded. Excluded songs will not appear in recommendations or radio.")
                        .font(.footnote)
                        .foregroundStyle(WaveColors.secondaryLabel)
                } else {
                    ForEach(settings.excludedSongIds, id: \.self) { songId in
                        Text(songId)
                            .font(.system(.body, design: .monospaced))
                    }
                    .onDelete(perform: remove)
                }
            }
        }
        .navigationTitle("Excluded songs")
        .toolbar {
            if !settings.excludedSongIds.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
    }

    private func add(_ songId: String) {
        guard !settings.excludedSongIds.contains(songId) else { return }
        settings.excludedSongIds.append(songId)
    }

    private func remove(at offsets: IndexSet) {
        settings.excludedSongIds.remove(atOffsets: offsets)
    }
}
