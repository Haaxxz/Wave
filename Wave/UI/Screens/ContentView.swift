import SwiftUI

/// The main shell: four tabs (Feed, Search, Library, Stats), each with its
/// own navigation stack, plus the mini player pinned above the tab bar and
/// the full player as a sheet.
///
/// The tab bar uses the classic `.tabItem` + `.tag` pattern, which works
/// back to iOS 16 — the newer `Tab(value:)` initialiser needs iOS 18.
struct ContentView: View {
    @Environment(Player.self) private var player
    @Environment(SettingsStore.self) private var settings

    @State private var router = AppRouter()
    @State private var showFullPlayer = false
    @State private var showSplash = true

    var body: some View {
        TabView(selection: $router.selectedTab) {
            NavigationStack(path: $router.feedPath) {
                FeedView()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("Feed", systemImage: "house") }
            .tag(AppTab.feed)

            NavigationStack(path: $router.searchPath) {
                SearchView()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(AppTab.search)

            NavigationStack(path: $router.libraryPath) {
                LibraryView()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("Library", systemImage: "books.vertical") }
            .tag(AppTab.library)

            NavigationStack(path: $router.statsPath) {
                StatsView()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("Stats", systemImage: "chart.bar") }
            .tag(AppTab.stats)
        }
        .safeAreaInset(edge: .bottom) {
            if player.currentTrack != nil {
                MiniPlayerView(onTap: { showFullPlayer = true })
            }
        }
        .sheet(isPresented: $showFullPlayer) {
            FullPlayerView()
        }
        .environment(router)
        .overlay {
            if showSplash {
                SplashView()
                    .task {
                        try? await Task.sleep(for: .seconds(1))
                        withAnimation(.easeOut(duration: 0.3)) { showSplash = false }
                    }
            }
        }
        .preferredColorScheme(colorScheme)
    }

    private var colorScheme: ColorScheme? {
        switch settings.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
