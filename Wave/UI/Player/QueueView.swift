import SwiftUI

// MARK: - Queue

/// The playback queue: the playing item is highlighted, items can be
/// swiped to delete, dragged to reorder, or tapped to jump to them.
struct QueueView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if player.queue.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 32))
                                .foregroundStyle(WaveColors.secondaryLabel)
                            Text("Queue is empty")
                                .font(WaveFonts.headline())
                            Text("Add songs from the feed or search and they will show up here.")
                                .font(WaveFonts.body(14))
                                .foregroundStyle(WaveColors.secondaryLabel)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    }
                } else {
                    ForEach(player.queue) { item in
                        QueueRow(
                            item: item,
                            isCurrent: currentItemID == item.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            jump(to: item)
                        }
                    }
                    .onDelete { player.removeFromQueue(at: $0) }
                    .onMove { player.moveQueue(from: $0, to: $1) }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var currentItemID: UUID? {
        guard player.queueIndex >= 0, player.queueIndex < player.queue.count else { return nil }
        return player.queue[player.queueIndex].id
    }

    private func jump(to item: QueueItem) {
        guard let index = player.queue.firstIndex(of: item) else { return }
        player.playAll(player.queue.map(\.track), startingAt: index)
        dismiss()
    }
}

// MARK: - Queue row

private struct QueueRow: View {
    var item: QueueItem
    var isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(thumbnails: item.track.thumbnails, size: 44, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.track.title)
                    .font(WaveFonts.body(14))
                    .foregroundStyle(isCurrent ? WaveColors.accent : WaveColors.label)
                    .lineLimit(1)
                Text(item.track.artistNames)
                    .font(WaveFonts.body(12))
                    .foregroundStyle(WaveColors.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer()

            if isCurrent {
                EqualizerBarsView()
            }

            if let durationSeconds = item.track.durationSeconds {
                Text(formatDuration(seconds: durationSeconds))
                    .font(WaveFonts.body(12))
                    .foregroundStyle(WaveColors.secondaryLabel)
                    .monospacedDigit()
            }
        }
    }
}
