import SwiftUI

// MARK: - Full player

/// The full-screen player sheet: large artwork, title and artist, seek bar,
/// transport controls, and actions for like, download, share, queue,
/// lyrics, EQ, sleep timer, tempo/pitch and Cast.
struct FullPlayerView: View {
    @Environment(Player.self) private var player
    @Environment(LibraryStoreImpl.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var showCast = false
    @State private var showTempo = false
    @State private var isSeeking = false
    @State private var seekValue: Double = 0

    var body: some View {
        ZStack {
            playerBackground
            if let track = player.currentTrack {
                playerContent(track)
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showQueue) {
            QueueView()
        }
        .sheet(isPresented: $showLyrics) {
            LyricsSheetView(onShare: { track, lyrics in
                dismissAndNavigate(to: .lyricsShare(track: track, lyrics: lyrics))
            })
        }
        .sheet(isPresented: $showCast) {
            castSheet
        }
        .sheet(isPresented: $showTempo) {
            tempoSheet
        }
    }

    // MARK: - Background and empty state

    private var playerBackground: some View {
        ZStack {
            WaveColors.background
            if let url = player.currentTrack?.artworkURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 80)
                            .opacity(0.35)
                    } else {
                        Color.clear
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(WaveColors.secondaryLabel)
                    .padding()
            }
            Image(systemName: "music.note")
                .font(.system(size: 48))
                .foregroundStyle(WaveColors.secondaryLabel)
            Text("Nothing playing")
                .font(WaveFonts.headline(18))
            Text("Pick a song from the feed, search or your library.")
                .font(WaveFonts.body(14))
                .foregroundStyle(WaveColors.secondaryLabel)
        }
    }

    // MARK: - Content

    private func playerContent(_ track: Track) -> some View {
        VStack(spacing: 0) {
            topBar

            ScrollView {
                VStack(spacing: 20) {
                    ArtworkView(thumbnails: track.thumbnails, size: 320, cornerRadius: 16)
                        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
                        .padding(.top, 8)

                    titleBlock(track)
                    seekSection
                    transportControls
                    actionRows(track)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(WaveColors.label)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Now Playing")
                .font(WaveFonts.headline(15))
                .foregroundStyle(WaveColors.secondaryLabel)
            Spacer()
            sleepTimerMenu
        }
        .padding(.horizontal, 12)
    }

    private func titleBlock(_ track: Track) -> some View {
        VStack(spacing: 4) {
            Text(track.title)
                .font(WaveFonts.title(22))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let artist = track.artists.first {
                Button(action: { dismissAndNavigate(to: .artist(id: artist.id)) }) {
                    Text(track.artistNames)
                        .font(WaveFonts.body(16))
                        .foregroundStyle(WaveColors.accent)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            } else {
                Text(track.artistNames)
                    .font(WaveFonts.body(16))
                    .foregroundStyle(WaveColors.secondaryLabel)
                    .lineLimit(1)
            }
            if let album = track.album {
                Button(action: { dismissAndNavigate(to: .album(id: album.id)) }) {
                    Text(album.title)
                        .font(WaveFonts.body(13))
                        .foregroundStyle(WaveColors.secondaryLabel)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var seekSection: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { isSeeking ? seekValue : player.positionSeconds },
                    set: { seekValue = $0 }
                ),
                in: 0...max(player.durationSeconds, 1),
                onEditingChanged: { editing in
                    isSeeking = editing
                    if !editing {
                        player.seek(to: seekValue)
                    }
                }
            )
            .tint(WaveColors.accent)
            HStack {
                Text(formatDuration(seconds: player.positionSeconds))
                    .font(WaveFonts.body(12))
                    .foregroundStyle(WaveColors.secondaryLabel)
                    .monospacedDigit()
                Spacer()
                Text(formatDuration(seconds: player.durationSeconds))
                    .font(WaveFonts.body(12))
                    .foregroundStyle(WaveColors.secondaryLabel)
                    .monospacedDigit()
            }
        }
    }

    private var transportControls: some View {
        HStack(spacing: 8) {
            Button(action: { player.isShuffleEnabled.toggle() }) {
                Image(systemName: "shuffle")
                    .font(.system(size: 20))
                    .foregroundStyle(player.isShuffleEnabled ? WaveColors.accent : WaveColors.label)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: { player.previous() }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(WaveColors.label)
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { player.togglePlayPause() }) {
                Image(systemName: playPauseIcon)
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(WaveColors.accent, in: Circle())
                    .shadow(color: WaveColors.accent.opacity(0.4), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(player.state == .loading)

            Button(action: { player.next() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(WaveColors.label)
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: { cycleRepeatMode() }) {
                Image(systemName: repeatIcon)
                    .font(.system(size: 20))
                    .foregroundStyle(player.repeatMode == .off ? WaveColors.label : WaveColors.accent)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var playPauseIcon: String {
        switch player.state {
        case .playing: return "pause.fill"
        case .loading: return "hourglass"
        default: return "play.fill"
        }
    }

    private var repeatIcon: String {
        player.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private func cycleRepeatMode() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }

    private func actionRows(_ track: Track) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 0) {
                actionButton(
                    systemName: isLiked(track) ? "heart.fill" : "heart",
                    label: "Like",
                    isActive: isLiked(track)
                ) {
                    Task { await library.toggleLike(track) }
                }
                actionButton(systemName: "arrow.down.circle", label: "Download") {
                    Task { await library.download(track) }
                }
                if let shareURL {
                    ShareLink(item: shareURL) {
                        actionButtonLabel(systemName: "square.and.arrow.up", label: "Share", isActive: false)
                    }
                    .buttonStyle(.plain)
                }
                actionButton(systemName: "list.bullet", label: "Queue") {
                    showQueue = true
                }
                actionButton(systemName: "quote.bubble", label: "Lyrics") {
                    showLyrics = true
                }
            }

            HStack(spacing: 0) {
                actionButton(systemName: "slider.horizontal.3", label: "EQ") {
                    dismissAndNavigate(to: .autoEQ)
                }
                actionButton(systemName: "speedometer", label: "Tempo") {
                    showTempo = true
                }
                actionButton(systemName: "tv", label: "Cast") {
                    showCast = true
                }
                Spacer()
            }
        }
    }

    private func actionButton(
        systemName: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            actionButtonLabel(systemName: systemName, label: label, isActive: isActive)
        }
        .buttonStyle(.plain)
    }

    private func actionButtonLabel(systemName: String, label: String, isActive: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 20))
                .foregroundStyle(isActive ? WaveColors.accent : WaveColors.label)
            Text(label)
                .font(WaveFonts.body(11))
                .foregroundStyle(WaveColors.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
    }

    private func isLiked(_ track: Track) -> Bool {
        library.likedSongs.contains(track)
    }

    private var shareURL: URL? {
        guard let track = player.currentTrack else { return nil }
        return URL(string: "https://music.youtube.com/watch?v=\(track.id)")
    }

    // MARK: - Sleep timer

    private var sleepTimerMenu: some View {
        Menu {
            Button(action: {
                player.cancelSleepTimer()
                settings.sleepTimerMinutes = 0
            }) {
                sleepTimerLabel(title: "Off", isCurrent: settings.sleepTimerMinutes == 0)
            }
            ForEach([15, 30, 60], id: \.self) { minutes in
                Button(action: {
                    player.setSleepTimer(minutes: minutes)
                    settings.sleepTimerMinutes = minutes
                }) {
                    sleepTimerLabel(title: "\(minutes) minutes", isCurrent: settings.sleepTimerMinutes == minutes)
                }
            }
        } label: {
            Image(systemName: settings.sleepTimerMinutes > 0 ? "moon.zzz.fill" : "moon.zzz")
                .font(.system(size: 18))
                .foregroundStyle(settings.sleepTimerMinutes > 0 ? WaveColors.accent : WaveColors.label)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func sleepTimerLabel(title: String, isCurrent: Bool) -> some View {
        if isCurrent {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: - Sheets

    private var castSheet: some View {
        VStack(spacing: 18) {
            Image(systemName: "tv.slash")
                .font(.system(size: 44))
                .foregroundStyle(WaveColors.secondaryLabel)
            Text(String(localized: "player.cast_unavailable"))
                .font(WaveFonts.body())
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Done") { showCast = false }
                .font(WaveFonts.headline())
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(WaveColors.accent, in: Capsule())
                .foregroundStyle(.white)
        }
        .padding()
        .presentationDetents([.medium])
    }

    private var tempoSheet: some View {
        NavigationStack {
            Form {
                Section("Playback speed") {
                    Stepper(
                        "Speed: \(player.playbackRate, specifier: "%.2f")×",
                        value: $player.playbackRate,
                        in: 0.5...2.0,
                        step: 0.05
                    )
                }
                Section("Pitch") {
                    Stepper(
                        "Pitch: \(Int(player.pitchSemitones)) semitones",
                        value: $player.pitchSemitones,
                        in: -12...12
                    )
                }
                Section {
                    Button("Reset speed and pitch") {
                        player.playbackRate = 1.0
                        player.pitchSemitones = 0
                    }
                }
            }
            .navigationTitle("Tempo & pitch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showTempo = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Navigation

    /// Dismisses the player sheet, then navigates in the tab the user was
    /// on. The short delay lets the sheet finish dismissing first.
    private func dismissAndNavigate(to route: Route) {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            router.navigate(route, in: router.selectedTab)
        }
    }
}
