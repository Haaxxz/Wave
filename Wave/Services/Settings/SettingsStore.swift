import Foundation

// MARK: - Settings

enum AudioQuality: String, Sendable, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    /// Approximate target bitrate in kbps, used when picking a stream format.
    var targetBitrateKbps: Int {
        switch self {
        case .low: return 128
        case .medium: return 192
        case .high: return 320
        }
    }
}

enum AppTheme: String, Sendable, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

/// The app-wide settings store. Single instance: `SettingsStore.shared`.
/// Backed by UserDefaults; every property persists on change.
@Observable
/// All access is main-actor-confined in practice (SwiftUI views and @MainActor
/// services), so the unchecked conformance is sound here.
final class SettingsStore: @unchecked Sendable {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isLoggedIn = defaults.bool(forKey: "isLoggedIn")
        self.userName = defaults.string(forKey: "userName") ?? ""
        self.visitorData = defaults.string(forKey: "visitorData")
        self.audioQuality = AudioQuality(rawValue: defaults.string(forKey: "audioQuality") ?? "") ?? .high
        self.downloadQuality = AudioQuality(rawValue: defaults.string(forKey: "downloadQuality") ?? "") ?? .high
        self.wifiOnlyDownloads = defaults.object(forKey: "wifiOnlyDownloads") as? Bool ?? true
        self.autoEQEnabled = defaults.bool(forKey: "autoEQEnabled")
        self.selectedHeadphone = defaults.string(forKey: "selectedHeadphone")
        self.automixEnabled = defaults.object(forKey: "automixEnabled") as? Bool ?? true
        self.loudnessNormalizationEnabled = defaults.object(forKey: "loudnessNormalizationEnabled") as? Bool ?? true
        self.skipSilenceEnabled = defaults.bool(forKey: "skipSilenceEnabled")
        self.sponsorBlockEnabled = defaults.object(forKey: "sponsorBlockEnabled") as? Bool ?? true
        self.sleepTimerMinutes = defaults.integer(forKey: "sleepTimerMinutes")
        self.theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        self.accentColorHex = defaults.string(forKey: "accentColorHex") ?? "#00D4B8"
        self.lastFmApiKey = defaults.string(forKey: "lastFmApiKey") ?? ""
        self.lastFmSessionKey = defaults.string(forKey: "lastFmSessionKey")
        self.lastFmApiSecret = defaults.string(forKey: "lastFmApiSecret") ?? ""
        self.spotifyClientId = defaults.string(forKey: "spotifyClientId") ?? ""
        self.spotifyClientSecret = defaults.string(forKey: "spotifyClientSecret") ?? ""
        self.homeSections = defaults.stringArray(forKey: "homeSections") ?? []
        self.excludedSongIds = defaults.stringArray(forKey: "excludedSongIds") ?? []
        self.searchHistory = defaults.stringArray(forKey: "searchHistory") ?? []
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
    }

    var isLoggedIn: Bool {
        didSet { defaults.set(isLoggedIn, forKey: "isLoggedIn") }
    }

    var userName: String {
        didSet { defaults.set(userName, forKey: "userName") }
    }

    /// YouTube `visitorData` from the poToken / session flow. Opaque string.
    var visitorData: String? {
        didSet { defaults.set(visitorData, forKey: "visitorData") }
    }

    var audioQuality: AudioQuality {
        didSet { defaults.set(audioQuality.rawValue, forKey: "audioQuality") }
    }

    var downloadQuality: AudioQuality {
        didSet { defaults.set(downloadQuality.rawValue, forKey: "downloadQuality") }
    }

    var wifiOnlyDownloads: Bool {
        didSet { defaults.set(wifiOnlyDownloads, forKey: "wifiOnlyDownloads") }
    }

    var autoEQEnabled: Bool {
        didSet { defaults.set(autoEQEnabled, forKey: "autoEQEnabled") }
    }

    var selectedHeadphone: String? {
        didSet { defaults.set(selectedHeadphone, forKey: "selectedHeadphone") }
    }

    var automixEnabled: Bool {
        didSet { defaults.set(automixEnabled, forKey: "automixEnabled") }
    }

    var loudnessNormalizationEnabled: Bool {
        didSet { defaults.set(loudnessNormalizationEnabled, forKey: "loudnessNormalizationEnabled") }
    }

    var skipSilenceEnabled: Bool {
        didSet { defaults.set(skipSilenceEnabled, forKey: "skipSilenceEnabled") }
    }

    var sponsorBlockEnabled: Bool {
        didSet { defaults.set(sponsorBlockEnabled, forKey: "sponsorBlockEnabled") }
    }

    /// 0 means no sleep timer.
    var sleepTimerMinutes: Int {
        didSet { defaults.set(sleepTimerMinutes, forKey: "sleepTimerMinutes") }
    }

    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "theme") }
    }

    var accentColorHex: String {
        didSet { defaults.set(accentColorHex, forKey: "accentColorHex") }
    }

    var lastFmApiKey: String {
        didSet { defaults.set(lastFmApiKey, forKey: "lastFmApiKey") }
    }

    var lastFmSessionKey: String? {
        didSet { defaults.set(lastFmSessionKey, forKey: "lastFmSessionKey") }
    }

    /// Last.fm API secret, used to sign authenticated calls (scrobbles).
    /// The secret is never a substitute for the session key; both are needed.
    var lastFmApiSecret: String {
        didSet { defaults.set(lastFmApiSecret, forKey: "lastFmApiSecret") }
    }

    var spotifyClientId: String {
        didSet { defaults.set(spotifyClientId, forKey: "spotifyClientId") }
    }

    var spotifyClientSecret: String {
        didSet { defaults.set(spotifyClientSecret, forKey: "spotifyClientSecret") }
    }

    /// Enabled home-section identifiers, in display order. Empty means all.
    var homeSections: [String] {
        didSet { defaults.set(homeSections, forKey: "homeSections") }
    }

    var excludedSongIds: [String] {
        didSet { defaults.set(excludedSongIds, forKey: "excludedSongIds") }
    }

    var searchHistory: [String] {
        didSet { defaults.set(searchHistory, forKey: "searchHistory") }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    func addSearchHistory(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = searchHistory.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        history.insert(trimmed, at: 0)
        searchHistory = Array(history.prefix(20))
    }

    func clearSearchHistory() {
        searchHistory = []
    }

    func signOut() {
        isLoggedIn = false
        userName = ""
        visitorData = nil
        lastFmSessionKey = nil
    }
}
