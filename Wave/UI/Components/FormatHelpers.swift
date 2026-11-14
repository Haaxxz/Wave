import Foundation

// MARK: - Shared formatting helpers

/// Formats a duration as `m:ss`. Returns `--:--` for missing values.
func formatDuration(seconds: Int?) -> String {
    guard let seconds, seconds > 0 else { return "--:--" }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// Formats a `Double` position (seconds) as `m:ss`.
func formatDuration(seconds: Double) -> String {
    formatDuration(seconds: Int(seconds))
}

/// Formats a large count (plays, subscribers) in compact form, e.g. `1.2M`.
func formatCompactCount(_ count: Int) -> String {
    switch count {
    case 1_000_000...:
        return String(format: "%.1fM", Double(count) / 1_000_000)
    case 1_000...:
        return String(format: "%.1fK", Double(count) / 1_000)
    default:
        return "\(count)"
    }
}
