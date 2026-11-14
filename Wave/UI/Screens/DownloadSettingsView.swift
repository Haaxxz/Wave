import SwiftUI

/// Download settings: quality, Wi-Fi-only, and clearing all downloads.
/// Files live in the app container — iOS has no shared storage for apps
/// to write into, so export uses the document picker instead.
struct DownloadSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LibraryStoreImpl.self) private var library

    @State private var showingDeleteAll = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Quality") {
                Picker("Download quality", selection: $settings.downloadQuality) {
                    ForEach(AudioQuality.allCases, id: \.self) { quality in
                        Text("\(quality.rawValue) — up to \(quality.targetBitrateKbps) kbps")
                            .tag(quality)
                    }
                }
                .pickerStyle(.navigationLink)
            }

            Section("Network") {
                Toggle("Download on Wi-Fi only", isOn: $settings.wifiOnlyDownloads)
                Text("When on, downloads pause on mobile data and resume on Wi-Fi.")
                    .font(.footnote)
                    .foregroundStyle(WaveColors.secondaryLabel)
            }

            Section("Storage") {
                HStack {
                    Text("Location")
                    Spacer()
                    Text("App container")
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
                HStack {
                    Text("Downloaded tracks")
                    Spacer()
                    Text("\(library.downloadedTracks.count)")
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
                Text("Downloads are stored inside Wave's own container and are removed with the app. To move a file out, use the share sheet on a downloaded track.")
                    .font(.footnote)
                    .foregroundStyle(WaveColors.secondaryLabel)
            }

            Section {
                Button("Delete all downloads", role: .destructive) {
                    showingDeleteAll = true
                }
                .disabled(library.downloadedTracks.isEmpty)
            }
        }
        .navigationTitle("Downloads")
        .alert("Delete all downloads?", isPresented: $showingDeleteAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete all", role: .destructive) {
                Task {
                    for downloaded in library.downloadedTracks {
                        await library.deleteDownload(downloaded.track)
                    }
                }
            }
        } message: {
            Text("This removes \(library.downloadedTracks.count) downloaded tracks from this device. Your likes and playlists are kept.")
        }
    }
}
