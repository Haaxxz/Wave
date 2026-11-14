import SwiftUI

/// Appearance: colour scheme, accent colour and the dynamic app icon.
/// The accent is stored as a hex string in `SettingsStore.accentColorHex`.
struct AppearanceSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    private let accentChoices: [(name: String, hex: String)] = [
        ("Wave teal", "#00D4B8"),
        ("Ocean blue", "#3B82F6"),
        ("Violet", "#8B5CF6"),
        ("Rose", "#F43F5E"),
        ("Amber", "#F59E0B"),
        ("Green", "#22C55E"),
    ]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Accent colour") {
                ForEach(accentChoices, id: \.hex) { choice in
                    Button {
                        settings.accentColorHex = choice.hex
                    } label: {
                        HStack {
                            Circle()
                                .fill(Color(hex: choice.hex))
                                .frame(width: 24, height: 24)
                            Text(choice.name)
                                .foregroundStyle(WaveColors.label)
                            Spacer()
                            if settings.accentColorHex.caseInsensitiveCompare(choice.hex) == .orderedSame {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(WaveColors.accent)
                            }
                        }
                    }
                }
                Text("The accent colours the player controls, links and highlights. The default Wave teal is #00D4B8.")
                    .font(.footnote)
                    .foregroundStyle(WaveColors.secondaryLabel)
            }

            Section("App icon") {
                if UIApplication.shared.supportsAlternateIcons {
                    HStack {
                        Text("Current icon")
                        Spacer()
                        Text(UIApplication.shared.alternateIconName ?? "Default")
                            .foregroundStyle(WaveColors.secondaryLabel)
                    }
                    Text("No alternate icons are bundled in this build. To offer them, add the icon sets under AppIcon in Assets.xcassets and list them in Info.plist under CFBundleAlternateIcons — they will then appear here.")
                        .font(.footnote)
                        .foregroundStyle(WaveColors.secondaryLabel)
                } else {
                    Text("This device does not support alternate app icons.")
                        .font(.footnote)
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
            }
        }
        .navigationTitle("Appearance")
    }
}

// MARK: - Hex colour helper

extension Color {
    /// Parses `#RRGGBB` (or `RRGGBB`); falls back to a neutral grey.
    init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
