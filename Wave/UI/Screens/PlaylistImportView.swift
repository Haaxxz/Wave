import SwiftUI

/// Import a playlist from another service by pasting its URL.
/// Spotify URLs are imported through `SpotifyService` (needs your own
/// Spotify developer app — see the Spotify login screen). Apple Music
/// and Tidal URLs are recognised and answered honestly: they are not
/// supported in this build, and nothing is faked.
struct PlaylistImportView: View {
    @Environment(LibraryStoreImpl.self) private var library
    @Environment(Player.self) private var player

    @State private var urlText = ""
    @State private var imported: Playlist?
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var saveNotice: String?

    private enum Provider {
        case spotify
        case appleMusic
        case tidal
        case unknown
    }

    private var detectedProvider: Provider {
        let lower = urlText.lowercased()
        if lower.contains("spotify.com") { return .spotify }
        if lower.contains("music.apple.com") { return .appleMusic }
        if lower.contains("tidal.com") { return .tidal }
        return .unknown
    }

    var body: some View {
        Form {
            Section("Playlist URL") {
                TextField("Paste a playlist link", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Import") {
                    Task { await importPlaylist() }
                }
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                if isImporting {
                    ProgressView("Importing…")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if detectedProvider == .appleMusic || detectedProvider == .tidal {
                Section {
                    Text("Apple Music and Tidal playlist import is not supported in this build. Only Spotify links can be imported — paste a Spotify playlist URL above.")
                        .font(.footnote)
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
            }

            if let imported {
                Section("Imported — \(imported.title)") {
                    if let author = imported.author {
                        Text("By \(author)")
                            .font(.footnote)
                            .foregroundStyle(WaveColors.secondaryLabel)
                    }
                    ForEach(imported.tracks) { track in
                        TrackRow(track: track)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(track) }
                    }
                }

                Section {
                    Button("Save to my library") {
                        Task { await save(imported) }
                    }
                    if let saveNotice {
                        Text(saveNotice)
                            .font(.footnote)
                            .foregroundStyle(WaveColors.secondaryLabel)
                    }
                }
            }
        }
        .navigationTitle("Import playlist")
    }

    private func importPlaylist() async {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        saveNotice = nil
        imported = nil

        switch detectedProvider {
        case .appleMusic:
            errorMessage = "Apple Music playlist import is not supported in this build."
            return
        case .tidal:
            errorMessage = "Tidal playlist import is not supported in this build."
            return
        case .unknown:
            errorMessage = "That does not look like a Spotify, Apple Music or Tidal playlist link."
            return
        case .spotify:
            break
        }

        isImporting = true
        defer { isImporting = false }
        do {
            imported = try await SpotifyService.shared.importPlaylist(url: url)
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func save(_ playlist: Playlist) async {
        await library.createPlaylist(title: playlist.title)
        guard let saved = library.playlists.first(where: { $0.title == playlist.title }) else {
            saveNotice = "The playlist was created, but it could not be found to add tracks to."
            return
        }
        for track in playlist.tracks {
            await library.addToPlaylist(track, playlistId: saved.id)
        }
        saveNotice = "Saved “\(playlist.title)” with \(playlist.tracks.count) tracks to your library."
    }
}
