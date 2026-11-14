import Foundation

// MARK: - Widget snapshot writer
//
// Writes the now-playing snapshot the widget extension reads. The snapshot
// goes into the shared App Group defaults (`group.app.wave`) under the key
// `nowPlayingSnapshot`; when the group is not configured (no App Groups
// entitlement in the repo — add `group.app.wave` in Xcode for live data),
// the writer silently does nothing and the widget shows its placeholder.

enum WidgetSnapshotWriter {
    static let suiteName = "group.app.wave"
    static let snapshotKey = "nowPlayingSnapshot"

    static func write(_ snapshot: WaveWidgetSnapshot) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    /// Reads the snapshot back (used by tests and the widget provider).
    static func read() -> WaveWidgetSnapshot? {
        guard
            let defaults = UserDefaults(suiteName: suiteName),
            let data = defaults.data(forKey: snapshotKey)
        else { return nil }
        return try? JSONDecoder().decode(WaveWidgetSnapshot.self, from: data)
    }
}
