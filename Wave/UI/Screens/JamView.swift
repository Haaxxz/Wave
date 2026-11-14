import SwiftUI

/// Listen Together (Jam): create a room and share its code, or join a
/// room with a code. While in a room, play/pause/seek stay in sync with
/// the other members through `JamClient`. The socket stays alive while
/// audio plays; iOS suspends it when the app backgrounds without audio.
struct JamView: View {
    @Environment(JamClient.self) private var jam
    @Environment(Player.self) private var player

    @State private var roomName = ""
    @State private var joinCode = ""
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var createdCode: String?

    var body: some View {
        Form {
            if let room = jam.room {
                roomSection(room: room)
            } else {
                createSection
                joinSection
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Listen Together")
        .disabled(isWorking)
    }

    // MARK: - Create / join

    private var createSection: some View {
        Section("Create a room") {
            TextField("Room name", text: $roomName)
            Button("Create room") {
                Task {
                    await run {
                        let code = try await jam.createRoom(name: roomName.trimmingCharacters(in: .whitespacesAndNewlines))
                        createdCode = code
                    }
                }
            }
            .disabled(roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let createdCode, let shareURL = URL(string: "https://jam.clashgram.org/?code=\(createdCode)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Join code")
                        Spacer()
                        Text(createdCode)
                            .font(.system(.body, design: .monospaced))
                            .bold()
                    }
                    ShareLink(item: shareURL) {
                        Label("Share invite link", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Text("Share the code or the link — anyone with it can join and listen along in sync.")
                .font(.footnote)
                .foregroundStyle(WaveColors.secondaryLabel)
        }
    }

    private var joinSection: some View {
        Section("Join a room") {
            TextField("Join code", text: $joinCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Join room") {
                Task {
                    await run {
                        try await jam.join(code: joinCode.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
            .disabled(joinCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - In a room

    private func roomSection(room: JamRoom) -> some View {
        Group {
            Section("Room") {
                HStack {
                    Text(room.name)
                        .font(WaveFonts.headline())
                    Spacer()
                    Text("Code: \(room.code)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(WaveColors.secondaryLabel)
                }
                Text("Host: \(room.hostName)")
                    .foregroundStyle(WaveColors.secondaryLabel)
                Text(jam.isConnected ? "Connected" : "Reconnecting…")
                    .foregroundStyle(jam.isConnected ? .green : .orange)
            }

            Section("Members (\(room.members.count))") {
                if room.members.isEmpty {
                    Text("Just you, for now.")
                        .foregroundStyle(WaveColors.secondaryLabel)
                } else {
                    ForEach(room.members, id: \.self) { member in
                        Label(member, systemImage: "person.fill")
                    }
                }
            }

            if let track = room.currentTrack {
                Section("Now playing") {
                    TrackRow(track: track)
                    HStack(spacing: 24) {
                        Button {
                            player.previous()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.title2)
                        }
                        Button {
                            Task {
                                // JamClient owns the player: sending
                                // play/pause both updates the room and
                                // drives local playback.
                                if room.isPlaying {
                                    await jam.sendPause()
                                } else {
                                    await jam.sendPlay()
                                }
                            }
                        } label: {
                            Image(systemName: room.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title)
                        }
                        Button {
                            player.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.title2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Slider(
                        value: Binding(
                            get: { player.positionSeconds },
                            set: { newValue in
                                Task { await jam.sendSeek(toMs: Int(newValue * 1000)) }
                                player.seek(to: newValue)
                            }
                        ),
                        in: 0...(player.durationSeconds > 0 ? player.durationSeconds : 1)
                    )
                }
            }

            Section {
                Button("Leave room", role: .destructive) {
                    Task {
                        await jam.leave()
                        createdCode = nil
                        joinCode = ""
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Runs a Jam call, showing a spinner while it is in flight and
    /// surfacing any error in the form instead of crashing. The work
    /// closure is `@MainActor` so it can update this view's state.
    private func run(_ work: @escaping @MainActor () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
