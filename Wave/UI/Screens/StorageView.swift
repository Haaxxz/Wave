import SwiftUI

/// Storage: how much space the app is using, and cache clearing.
/// Downloads are excluded from "cached data" — they are deleted from the
/// Downloads screen or Download settings instead.
struct StorageView: View {
    @Environment(LibraryStoreImpl.self) private var library

    @State private var downloadsSize: Int = 0
    @State private var cacheSize: Int = 0
    @State private var showingClearCache = false
    @State private var showingClearAll = false
    @State private var notice: String?

    private let fileManager = FileManager.default

    var body: some View {
        Form {
            Section("Usage") {
                HStack {
                    Text("Downloads")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(downloadsSize), countStyle: .file))
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
                HStack {
                    Text("Cached data")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file))
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
                HStack {
                    Text("Total")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(downloadsSize + cacheSize), countStyle: .file))
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
            }

            Section {
                Button("Clear image cache") {
                    clearCaches()
                }
                .disabled(cacheSize == 0)
                Button("Clear all cached data", role: .destructive) {
                    showingClearAll = true
                }
                .disabled(cacheSize == 0)
            } footer: {
                Text("Cached data is artwork, search results and temporary files. Clearing it never touches your downloads, likes or playlists.")
            }

            if let notice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
            }
        }
        .navigationTitle("Storage")
        .task { refreshSizes() }
        .alert("Clear all cached data?", isPresented: $showingClearAll) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                clearCaches()
            }
        } message: {
            Text("This removes cached artwork and temporary files. Your downloads, likes and playlists are kept.")
        }
    }

    // MARK: - Size measurement

    private var downloadsDirectory: URL? {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    private var cachesDirectory: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    private func refreshSizes() {
        downloadsSize = size(of: downloadsDirectory)
        cacheSize = size(of: cachesDirectory)
    }

    /// The summed size of every file under a directory, or 0 when the
    /// directory does not exist or cannot be read.
    private func size(of directory: URL?) -> Int {
        guard let directory,
              let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
              )
        else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += size
            }
        }
        return total
    }

    // MARK: - Clearing

    private func clearCaches() {
        guard let cachesDirectory else { return }
        let contents = (try? fileManager.contentsOfDirectory(
            at: cachesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        var removed = 0
        for url in contents {
            if (try? fileManager.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        refreshSizes()
        notice = removed > 0
            ? "Cleared \(removed) cached item\(removed == 1 ? "" : "s")."
            : "Nothing was cleared — the cache was already empty."
    }
}
