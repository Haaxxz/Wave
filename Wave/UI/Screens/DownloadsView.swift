import SwiftUI

/// Downloaded tracks on this device, with file size and date.
/// Tapping a track plays the local file; swiping deletes the download.
/// The download itself is owned by `LibraryStoreImpl`.
struct DownloadsView: View {
    @Environment(LibraryStoreImpl.self) private var library
    @Environment(Player.self) private var player

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        Group {
            if library.downloadedTracks.isEmpty {
                ContentUnavailableView(
                    "No downloads yet",
                    systemImage: "arrow.down.circle",
                    description: Text("Download a track from its menu and it will be available here, even offline.")
                )
            } else {
                List {
                    ForEach(library.downloadedTracks) { downloaded in
                        HStack(spacing: 12) {
                            ArtworkView(thumbnails: downloaded.track.thumbnails, size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(downloaded.track.title)
                                    .font(WaveFonts.headline(15))
                                    .lineLimit(1)
                                Text(downloaded.track.artistNames)
                                    .font(.footnote)
                                    .foregroundStyle(WaveColors.secondaryLabel)
                                    .lineLimit(1)
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(downloaded.fileSize), countStyle: .file)) · \(dateFormatter.string(from: downloaded.downloadedAt))")
                                    .font(.caption)
                                    .foregroundStyle(WaveColors.secondaryLabel)
                            }
                            Spacer()
                            Image(systemName: "play.circle")
                                .foregroundStyle(WaveColors.secondaryLabel)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // The player resolves downloaded tracks to
                            // their local file before streaming.
                            player.play(downloaded.track)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await library.deleteDownload(downloaded.track) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Downloads")
    }
}
