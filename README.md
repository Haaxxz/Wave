# Wave — iOS clone of LastWave

Wave is a clean-room SwiftUI reimplementation of **LastWave 5.2.1**, the Android
YouTube Music client, built for iOS. Same screens, same functions, same
behaviour — to the best of what iOS allows.

It is **unofficial and not affiliated with YouTube, Google, Spotify, or the
LastWave authors**. It streams YouTube Music through the same private InnerTube
endpoints the Android app uses. The original Android app is GPLv3; this
reimplementation is GPLv3 too. See `LICENSE`.

## What works

- Browse the YouTube Music home feed, charts, moods, genres and new releases.
- Search with suggestions, artist / album / playlist detail pages.
- Playback with queue, shuffle, repeat, radio ("Start Mix"), sleep timer,
  skip-silence, tempo and pitch.
- 15-band parametric EQ with AutoEQ headphone presets, loudness
  normalisation (ReplayGain / LUFS), Automix DJ transitions.
- Synced lyrics from public providers (LRCLIB and others), karaoke view,
  romanisation and translation, share-as-quote-cards.
- Library, playlists, M3U export, backup and restore.
- Downloads with tag writing and `.lrc` sidecars.
- Listen Together (Jam) rooms over WebSocket.
- Last.fm scrobbling, Spotify and Apple Music playlist import.
- Podcasts, local taste-based playlist generator, statistics.
- Home-screen widgets (Now Playing and Wave designs).
- YouTube account login with bidirectional sync (likes, history, library).

## What does not work on iOS

Three features from the Android app are **impossible** on iOS, not just
missing. They are left out on purpose.

| Feature | Why |
| --- | --- |
| Bit-perfect USB DAC output | iOS gives apps no USB host audio API and no exclusive mode. All audio passes through the system mixer. The app uses `AVAudioEngine` with a preferred sample-rate hint instead. The "bit-perfect" claim is dropped. |
| Discord Rich Presence | Discord offers no Rich Presence / IPC API on iOS. The Game SDK is desktop-only. |
| In-app self-update | iOS forbids apps that update themselves. The app checks its version against GitHub releases and points at the release page instead. |

Severely limited:

- **Widevine-DRM lossless addons.** The addon system itself ports, and clear
  (non-DRM) FLAC streams play. Widevine CENC streams do not — Widevine has
  no CDM on iOS; Apple permits only FairPlay. The private addon and lyrics
  backends from the Android app cannot be reproduced either (their secrets
  were never in the repo). Use public endpoints or your own server.
- **Local music library scan.** iOS has no device-wide media scan. The app
  reads the Apple Music library (`MPMediaLibrary`) and files you pick with
  the document picker. No background folder watching.
- **CarPlay.** Technically possible (`MPPlayableContentManager`), but it
  needs Apple's `com.apple.developer.carplay-audio` entitlement, granted
  per app after review. Not guaranteed for an unofficial YouTube client.
- **Widgets.** WidgetKit has a timeline refresh budget, so progress between
  refreshes is estimated. No sub-minute live progress.
- **System-wide EQ sessions.** In-app EQ only.
- **Google Cast.** Not in this build. It needs the Google Cast iOS SDK
  (CocoaPods) and local-network entitlements. See `docs/ARCHITECTURE.md`.

## Distribution

Do **not** expect this in the App Store. A faithful clone streams YouTube
Music without authorisation and circumvents BotGuard; Apple routinely
rejects such apps (Guideline 5.2.3 / 4.2). The realistic path is
**sideloading** (AltStore, or TestFlight / EU DMA distribution).

The app ships under the name **Wave**, not LastWave, and with its own icon.
The Android app is GPLv3; App Store terms conflict with GPLv3, so do not
submit it there under either name.

## Build with GitHub Actions

Push to `main`. The workflow (`.github/workflows/ios.yml`) runs on the
`macos-26` runner with Xcode 26:

1. Installs XcodeGen.
2. Generates the Xcode project from `project.yml`.
3. Builds the app unsigned.
4. Runs the unit tests on the iPhone 16 simulator.
5. Packages an **unsigned `.ipa`** and uploads it as an artifact.

Download the artifact, sign it with your own Apple ID (AltStore, SideStore,
or `ios-app-signer`), and install it. A free Apple ID allows 3 sideloaded
apps with a 7-day expiry.

## Build on a Mac

```sh
brew install xcodegen
xcodegen generate
open Wave.xcodeproj
```

Select the `Wave` scheme and run on a device or simulator. No signing is
needed for the simulator. For a device, set your own development team and
bundle identifier in Xcode (the default is `app.wave`).

## First run

No API keys are bundled. On first launch:

- **YouTube login** is optional. Without it you get anonymous browsing and
  playback. With it (in-app WebView sign-in, cookies stay on the device)
  you get likes, history and library sync.
- **Last.fm**: enter your API key in Settings → Integrations to scrobble.
- **Spotify**: playlist import uses your own Spotify developer credentials
  in Settings → Integrations.
- **Widgets**: live Now Playing data needs an App Group. In Xcode, add the
  `group.app.wave` App Group capability to both the app and the widget
  targets. Until then the widget shows a placeholder.

## Project layout

```
project.yml            XcodeGen project definition (the .xcodeproj is generated)
Wave/                  App target (Swift 6, SwiftUI, iOS 17+)
  App/                 App entry point, dependency wiring
  Models/              Plain data models (Track, Album, Artist, Playlist, ...)
  Services/
    InnerTube/         YouTube Music API client, stream resolution, poToken
    Playback/          Player, queue, EQ, loudness, Automix
    Lyrics/            Lyrics providers (LRCLIB and others)
    Library/           SwiftData store, downloads, tag writing
    Social/            Jam, Last.fm, Spotify, Apple Music import
    Settings/          Settings store
  UI/
    Theme/             Colours, typography, Liquid Glass helpers
    Navigation/        Route enum, app router
    Components/        Shared rows, cards, artwork views
    Screens/           All 30 destinations
    Player/            Mini player, full player, queue, lyrics sheet
WaveWidgets/           WidgetKit extension (Now Playing, Wave widgets)
WaveTests/             Unit tests (InnerTube parsing, decipher, lyrics, EQ, Jam)
docs/                  SPECS.md (protocol reference), ARCHITECTURE.md, CONTRACTS.md
```

No third-party dependencies. Only Apple frameworks.

## How it works

- **InnerTube.** The app talks to `music.youtube.com/youtubei/v1` with the
  `WEB_REMIX` client, the same endpoints the Android app uses. See
  `docs/SPECS.md` for the endpoint and request shapes.
- **Stream URLs.** The player endpoint returns adaptive formats; ciphered
  signatures are deciphered from YouTube's player JavaScript, the same way
  NewPipe does it. Never use `IOS`-family audio URLs — there is no mintable
  iOS GVS token.
- **poToken.** BotGuard challenges run in a headless `WKWebView`, mirroring
  the Android app's minter. This is fragile by nature: YouTube changes the
  challenge, and the minter has to follow.
- **Automix.** The Android DSP (dual-deck, crossover, LUFS contour,
  transient-preserving stretch) is ported to `AVAudioEngine` where it fits;
  the dual-deck transport is simplified to a single-engine crossfade.
- **Audio pipeline.** `AVAudioEngine` + `AVAudioUnitEQ` for EQ,
  `AVAudioUnitTimePitch` for tempo/pitch, `AVPlayer` for streamed video
  and SponsorBlock segments.

## License

GNU General Public License v3.0 — see `LICENSE`.
