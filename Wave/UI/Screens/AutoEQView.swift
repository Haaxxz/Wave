import Foundation
import SwiftUI

/// AutoEQ: per-headphone correction curves, applied through the player's
/// `AVAudioUnitEQ` chain. Presets come from the bundled
/// `autoeq_presets.json`, which holds oratory1990-style parametric filters
/// per headphone (`name`, `formFactor`, `preampDb`, `filters` with
/// `type`/`frequencyHz`/`gainDb`/`q`) plus target curves. Picking a
/// headphone evaluates its filters at the 15 EQ band frequencies and
/// applies the resulting gains to the player's live EQ settings.
///
/// The 15 band frequencies, low to high, are the same ladder as
/// `EQSettings.bandFrequencies`: 25, 40, 63, 100, 160, 250, 400, 630,
/// 1000, 1600, 2500, 4000, 6300, 10000 and 16000 Hz.
struct AutoEQView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(Player.self) private var player

    @State private var library: AutoEQLibrary?
    @State private var headphones: [AutoEQPreset] = []
    @State private var loadError: String?

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Toggle("Enable AutoEQ", isOn: $settings.autoEQEnabled)
                Text("When enabled, the selected headphone's correction curve is applied to everything you play, through AVAudioUnitEQ.")
                    .font(.footnote)
                    .foregroundStyle(WaveColors.secondaryLabel)
            }

            Section("Headphones") {
                if let loadError {
                    Text(loadError)
                        .foregroundStyle(.red)
                } else if headphones.isEmpty {
                    ProgressView("Loading presets…")
                } else {
                    ForEach(headphones) { headphone in
                        Button {
                            settings.selectedHeadphone = headphone.name
                            apply(headphone)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(headphone.name)
                                        .foregroundStyle(WaveColors.label)
                                    Text("\(headphone.formFactor.rawValue) · \(headphone.source) · preamp \(String(format: "%+.1f dB", headphone.preampDb))")
                                        .font(.footnote)
                                        .foregroundStyle(WaveColors.secondaryLabel)
                                }
                                Spacer()
                                if settings.selectedHeadphone == headphone.name {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(WaveColors.accent)
                                }
                            }
                        }
                    }
                }
            }

            Section("Equalizer — 15 bands") {
                if settings.autoEQEnabled {
                    @Bindable var player = player
                    ForEach(EQSettings.bandFrequencies.indices, id: \.self) { index in
                        HStack {
                            Text(bandLabel(for: index))
                                .font(.footnote)
                                .frame(width: 64, alignment: .leading)
                                .foregroundStyle(WaveColors.secondaryLabel)
                            Slider(value: $player.eqSettings.gains[index], in: -12...12, step: 0.5)
                            Text(String(format: "%+.1f dB", player.eqSettings.gains[index]))
                                .font(.footnote)
                                .frame(width: 56, alignment: .trailing)
                                .foregroundStyle(WaveColors.secondaryLabel)
                        }
                    }
                    Button("Reset to flat") {
                        player.eqSettings = .flat
                    }
                } else {
                    Text("Turn AutoEQ on to adjust the bands.")
                        .font(.footnote)
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
            }
        }
        .navigationTitle("AutoEQ")
        .task {
            library = AutoEQLibrary.load()
            headphones = library?.presets ?? []
            if headphones.isEmpty {
                loadError = "No AutoEQ presets were found in the app bundle."
            }
        }
    }

    private func bandLabel(for index: Int) -> String {
        let hz = EQSettings.bandFrequencies[index]
        return hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }

    /// Applies a headphone's correction curve to the player's live EQ
    /// settings (evaluated at the 15 band frequencies by the library).
    /// Picking a headphone also turns the EQ on when AutoEQ is enabled.
    private func apply(_ headphone: AutoEQPreset) {
        guard let library else { return }
        player.eqSettings = library.eqSettings(for: headphone)
        player.eqEnabled = settings.autoEQEnabled
    }
}
