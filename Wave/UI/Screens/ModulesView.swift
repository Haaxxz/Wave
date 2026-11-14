import SwiftUI

/// Feature modules: each toggle is advisory. The relevant service checks
/// its flag before doing the work — turning "Lyrics providers" off, for
/// example, makes lyric lookups return nothing. Flags are stored in
/// UserDefaults under `module.<name>` so they survive restarts.
struct ModulesView: View {
    private struct Module: Identifiable {
        var id: String { key }
        var key: String
        var title: String
        var description: String
    }

    private let modules: [Module] = [
        Module(
            key: "lyrics",
            title: "Lyrics providers",
            description: "Look up synced and plain lyrics from LRCLIB and the other public providers."
        ),
        Module(
            key: "automix",
            title: "Automix",
            description: "DJ-style crossfades and transitions between tracks."
        ),
        Module(
            key: "sponsorblock",
            title: "SponsorBlock",
            description: "Skip sponsored segments in videos."
        ),
        Module(
            key: "lastfm",
            title: "Last.fm",
            description: "Scrobble what you play and show Last.fm stats and friends."
        ),
        Module(
            key: "spotifyImport",
            title: "Spotify import",
            description: "Import playlists and liked songs from Spotify."
        ),
        Module(
            key: "jam",
            title: "Jam (Listen Together)",
            description: "Create and join real-time listening rooms."
        ),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(modules) { module in
                    ModuleRow(module: module)
                }
            } footer: {
                Text("These switches only enable or disable the feature. Turning a module off does not delete any data or sign you out of the linked service.")
            }
        }
        .navigationTitle("Modules")
    }

    private struct ModuleRow: View {
        var module: Module

        var body: some View {
            Toggle(isOn: binding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title)
                    Text(module.description)
                        .font(.footnote)
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
            }
        }

        /// Each module gets its own `module.<key>` UserDefaults flag.
        /// `@AppStorage` needs a static key, so the binding is built
        /// manually from UserDefaults instead.
        private var binding: Binding<Bool> {
            Binding(
                get: {
                    UserDefaults.standard.object(forKey: "module.\(module.key)") as? Bool ?? true
                },
                set: { newValue in
                    UserDefaults.standard.set(newValue, forKey: "module.\(module.key)")
                }
            )
        }
    }
}
