import SwiftUI

/// Wave — the iOS clone of LastWave. SwiftUI lifecycle, no AppDelegate.
/// Services are shared singletons (see docs/CONTRACTS.md); screens take them
/// from the environment as concrete types, e.g. `@Environment(Player.self)`.
@main
struct WaveApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(SettingsStore.shared)
                .environment(Player.shared)
                .environment(InnerTubeClient.shared)
                .environment(LibraryStoreImpl.shared)
                .environment(JamClient.shared)
                .environment(LyricsProvider.shared)
        }
    }
}
