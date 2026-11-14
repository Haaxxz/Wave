import SwiftUI

/// Which sections the home feed shows, and in what order.
/// `SettingsStore.homeSections` holds the enabled section titles in
/// display order; an empty list means "show all sections". Disabled
/// sections stay in this list (unchecked) so they can be turned back on.
struct HomeSectionsView: View {
    @Environment(SettingsStore.self) private var settings

    /// Every section the feed can show. The order here is the default
    /// order used when nothing has been customised yet.
    private static let allSections = [
        "Quick picks",
        "New releases",
        "Charts",
        "Moods & genres",
        "Top songs",
        "Recommended albums",
        "Similar artists",
        "Podcasts",
    ]

    /// Rows in display order: the stored order first, then any section
    /// that is not in the stored list (disabled ones, or new sections
    /// added in a later version) appended at the end.
    private var displayOrder: [String] {
        var order = settings.homeSections
        for section in Self.allSections where !order.contains(section) {
            order.append(section)
        }
        return order
    }

    var body: some View {
        List {
            Section {
                ForEach(displayOrder, id: \.self) { section in
                    HStack {
                        Text(section)
                        Spacer()
                        if isEnabled(section) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(WaveColors.accent)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(section) }
                }
                .onMove(perform: move)
            } header: {
                Text("Sections")
            } footer: {
                Text("Tap a section to show or hide it on the home feed. Drag the handle on the right to reorder. Hiding every section is not allowed — at least one stays on.")
            }
        }
        .navigationTitle("Home sections")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }

    private func isEnabled(_ section: String) -> Bool {
        // Empty means "all enabled", so a section is disabled only when a
        // custom list exists and does not contain it.
        settings.homeSections.isEmpty || settings.homeSections.contains(section)
    }

    private func toggle(_ section: String) {
        if isEnabled(section) {
            // Hiding: materialise the full list first, then remove one.
            var current = displayOrder
            current.removeAll { $0 == section }
            // Hiding everything would leave an empty list, which means
            // "all" — so keep at least one section enabled.
            guard !current.isEmpty else { return }
            settings.homeSections = current
        } else {
            // Showing: append it to the stored order.
            settings.homeSections = displayOrder.filter { isEnabled($0) } + [section]
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var order = displayOrder
        order.move(fromOffsets: source, toOffset: destination)
        // Persist only the enabled sections, in the new order.
        settings.homeSections = order.filter { isEnabled($0) }
    }
}
