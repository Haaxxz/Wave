import SwiftUI
import WidgetKit

// MARK: - Wave widgets
//
// Two WidgetKit widgets reading the snapshot the app writes into the shared
// App Group defaults (`group.app.wave`, key `nowPlayingSnapshot`) — see
// `WidgetSnapshotWriter` in the app target. When the group is not
// configured, or the app has never played anything, both widgets show their
// placeholder state ("Open Wave to start listening").
//
//  - `NowPlayingWidget` — compact now-playing card (.systemSmall /
//    .systemMedium): artwork, title, artist, play state and progress.
//  - `WaveWidget` — large artwork-first card (.systemMedium / .systemLarge).

@main
struct WaveWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        WaveWidget()
    }
}

// MARK: - Timeline

struct NowPlayingEntry: TimelineEntry {
    var date: Date
    var snapshot: WaveWidgetSnapshot?
}

/// Reads the snapshot from the shared App Group defaults and refreshes on a
/// 15-minute timeline policy (the app also rewrites the snapshot on every
/// track change, so the widget updates promptly while playing).
struct WaveWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), snapshot: sampleSnapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: Date(), snapshot: readSnapshot() ?? sampleSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let entry = NowPlayingEntry(date: Date(), snapshot: readSnapshot())
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func readSnapshot() -> WaveWidgetSnapshot? {
        guard
            let defaults = UserDefaults(suiteName: "group.app.wave"),
            let data = defaults.data(forKey: "nowPlayingSnapshot")
        else { return nil }
        return try? JSONDecoder().decode(WaveWidgetSnapshot.self, from: data)
    }

    private func sampleSnapshot() -> WaveWidgetSnapshot {
        WaveWidgetSnapshot(
            trackTitle: "Wave",
            artistName: "Now Playing",
            artworkURL: nil,
            isPlaying: true,
            positionSeconds: 42,
            durationSeconds: 214,
            updatedAt: Date()
        )
    }
}

// MARK: - Shared views

private struct WidgetArtworkView: View {
    var url: URL?
    var size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    artworkPlaceholder
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.secondary.opacity(0.25))
            .overlay(
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            )
    }
}

private struct WidgetProgressView: View {
    var positionSeconds: Double
    var durationSeconds: Double

    var body: some View {
        if durationSeconds > 0 {
            ProgressView(value: min(1, max(0, positionSeconds / durationSeconds)))
                .tint(.white.opacity(0.8))
        }
    }
}

private struct WidgetEmptyView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note.list")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open Wave to start listening")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Now Playing widget

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlayingWidget", provider: WaveWidgetProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("See what's playing in Wave, with progress.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct NowPlayingWidgetView: View {
    var entry: NowPlayingEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot, snapshot.trackTitle != nil {
            switch family {
            case .systemSmall:
                VStack(alignment: .leading, spacing: 8) {
                    WidgetArtworkView(url: snapshot.artworkURL, size: 56)
                    Text(snapshot.trackTitle ?? "")
                        .font(.headline)
                        .lineLimit(2)
                    Text(snapshot.artistName ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                            .font(.caption2)
                        WidgetProgressView(positionSeconds: snapshot.positionSeconds, durationSeconds: snapshot.durationSeconds)
                    }
                }
                .padding(4)
            default:
                HStack(spacing: 12) {
                    WidgetArtworkView(url: snapshot.artworkURL, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.trackTitle ?? "")
                            .font(.headline)
                            .lineLimit(2)
                        Text(snapshot.artistName ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                                .font(.caption)
                            WidgetProgressView(positionSeconds: snapshot.positionSeconds, durationSeconds: snapshot.durationSeconds)
                        }
                    }
                }
            }
        } else {
            WidgetEmptyView()
        }
    }
}

// MARK: - Wave widget (large artwork)

struct WaveWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WaveWidget", provider: WaveWidgetProvider()) { entry in
            WaveWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Wave")
        .description("Your music, big artwork first.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct WaveWidgetView: View {
    var entry: NowPlayingEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot, snapshot.trackTitle != nil {
            if family == .systemLarge {
                VStack(spacing: 12) {
                    WidgetArtworkView(url: snapshot.artworkURL, size: 180)
                    Text(snapshot.trackTitle ?? "")
                        .font(.title3.bold())
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(snapshot.artistName ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                            .font(.caption)
                        WidgetProgressView(positionSeconds: snapshot.positionSeconds, durationSeconds: snapshot.durationSeconds)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            } else {
                HStack(spacing: 12) {
                    WidgetArtworkView(url: snapshot.artworkURL, size: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snapshot.trackTitle ?? "")
                            .font(.title3.bold())
                            .lineLimit(2)
                        Text(snapshot.artistName ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                                .font(.caption)
                            WidgetProgressView(positionSeconds: snapshot.positionSeconds, durationSeconds: snapshot.durationSeconds)
                        }
                    }
                }
            }
        } else {
            WidgetEmptyView()
        }
    }
}
