import SwiftUI

/// Audio playback settings: stream quality, loudness, silence skipping,
/// SponsorBlock and Automix, plus a tempo/pitch reset for the player.
struct AudioSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(Player.self) private var player

    var body: some View {
        Form {
            Section("Quality") {
                Picker("Audio quality", selection: $settings.audioQuality) {
                    ForEach(AudioQuality.allCases, id: \.self) { quality in
                        Text("\(quality.rawValue) — up to \(quality.targetBitrateKbps) kbps")
                            .tag(quality)
                    }
                }
                .pickerStyle(.navigationLink)
            }

            Section("Playback") {
                Toggle("Loudness normalisation", isOn: $settings.loudnessNormalizationEnabled)
                Toggle("Skip silence", isOn: $settings.skipSilenceEnabled)
                Toggle("SponsorBlock", isOn: $settings.sponsorBlockEnabled)
                Toggle("Automix (DJ transitions)", isOn: $settings.automixEnabled)
                Text("SponsorBlock skips sponsored segments in videos. Automix crossfades between tracks with DJ-style transitions.")
                    .font(.footnote)
                    .foregroundStyle(WaveColors.secondaryLabel)
            }

            Section("Tempo & pitch") {
                HStack {
                    Text("Playback rate")
                    Spacer()
                    Text(String(format: "%.2fx", player.playbackRate))
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
                HStack {
                    Text("Pitch shift")
                    Spacer()
                    Text("\(Int(player.pitchSemitones)) semitones")
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
                Button("Reset tempo & pitch") {
                    player.playbackRate = 1.0
                    player.pitchSemitones = 0
                }
                .disabled(player.playbackRate == 1.0 && player.pitchSemitones == 0)
            }
        }
        .navigationTitle("Audio")
    }
}
