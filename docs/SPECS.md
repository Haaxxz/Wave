# SPECS — protocol reference for the Wave iOS clone

This documents what the Swift implementation in this repo actually does, so
a future reader can check it against the Android reference
(`LastWave 5.2.1`, `com.lastwave.app`) without re-reading both codebases.
Where the Android app and this clone differ, the difference is stated.

## InnerTube (YouTube Music)

- Base: `https://music.youtube.com/youtubei/v1` (music), with
  `https://www.youtube.com/youtubei/v1` for a few calls.
- Client: `WEB_REMIX` (client id 67). The client version and API key are
  bootstrapped at runtime from the `music.youtube.com` homepage; the
  bundled fallback version is `1.20260707.12.00` and the fallback key is
  the public web-client key YouTube itself ships in its pages. No keys
  were taken from the Android repo.
- Requests are `POST` with a JSON body: `context.client` (name, version,
  `hl`, `gl`, `deviceMake`/`deviceModel` when known) plus the
  endpoint-specific fields, and `?key=<apiKey>` on the URL.
- Endpoints used: `browse` (home, artist, album, playlist, charts,
  genres, new releases), `search`, `next` (queue / radio), `player`
  (stream URLs), `like` (rate a track), and search suggestions from
  `suggestqueries.google.com/complete/search?client=firefox&ds=yt`
  (fallback host `suggestqueries-clients6.youtube.com`).
- Responses are parsed defensively from YouTube's renderer structures
  (`musicResponsiveListItemRenderer`, `musicTwoRowItemRenderer`,
  `musicShelfRenderer`, …). A missing field never throws the whole
  response away; the parser skips that item.
- Auth: when logged in, requests carry the `SAPISIDHASH` header
  (SHA-1 of `<timestamp> <SAPISID> https://music.youtube.com`, from the
  `SAPISID` cookie) and the `visitorData` from the session. The login
  WebView writes cookies into the shared `HTTPCookieStorage`.
- **Never use `IOS`-family clients for audio URLs.** There is no mintable
  iOS GVS token, and those URLs fail without one. The clone uses
  `WEB_REMIX` audio formats only.

## Stream resolution

- `player` returns `streamingData.adaptiveFormats`. The clone picks the
  best audio-only format for the target bitrate
  (`SettingsStore.audioQuality`, capped at 192 kbps on cellular), preferring
  `audio/mp4` — AVFoundation cannot play Opus/WebM.
- Ciphered signatures are deciphered by fetching the player JavaScript
  (`jsUrl` from the player response), extracting the decipher and
  throttling functions by fingerprint, and evaluating the real JS in
  JavaScriptCore. A ciphered format whose function cannot be extracted is
  skipped, never guessed. The `pot=` parameter is appended when a poToken
  is available.
- Playback fetches in chunks: the player requests byte ranges rather than
  downloading whole files.

## poToken (BotGuard)

- Full flow, mirroring the Android minter: `Create` → parse the challenge
  → run it in a headless `WKWebView` → `GenerateIT` → mint the session
  token. `PoTokenGenerator.token()` returns the token; `visitorData` is
  persisted to settings.
- Every step has a typed error. If generation fails, playback continues
  without a token and YouTube may reject some streams — the failure is
  surfaced, not hidden, and no fake token is ever returned.

## Jam (Listen Together)

- WebSocket: `wss://jam.clashgram.org/ws`. HTTP base for room counts:
  `https://jam.clashgram.org`.
- Envelope: `{"type": "<message>", "payload": {...}}`, snake_case fields.
- Client → server: `create_room`, `join_room`, `leave_room`, `send_chat`,
  `playback_action`, `ping`, `grant_host`, `transfer_host`, `revoke_host`,
  `station_mode`, `queue_update`, `cooldown`, `queue_updated`,
  `change_room_mode`.
- Server → client: `room_created`, `sync_state`, `user_joined`,
  `user_left`, `chat_message`, `sync_playback`, `host_changed`,
  `cohost_changed`, `room_mode_changed`, `station_mode`, `pong`, `error`.
- Behaviour: 15 s join timeout, ping every 25 s, reconnect up to 3×,
  echo suppression (own `from_user_id` + 800 ms quiet window),
  latency-compensated positions (server timestamp, capped 5 s), 2 s drift
  threshold, host/collaborative control rules, queue publishing (host,
  top 5), live-station rejoin every 2 s for non-hosts. Stations: INDIA,
  WORLD.
- Deep links: `wave://jam?code=…` and
  `https://jam.clashgram.org/?code=…`.

## Lyrics

Provider chain, in order, all keyless:

1. **LRCLIB** — `https://lrclib.net/api/get` (exact: track, artist,
   album, duration), then `/api/search`. Exact match is tried with
   progressively looser parameters (album, then duration, then neither),
   then a cleaned title, then search with tiered duration tolerance
   (≤8 s, then ≤30 s). Version tags (live/remix/acoustic/…) must match
   on both sides or the record is rejected.
2. **SimpMusic** — `https://api-lyrics.simpmusic.org/v1/{videoId}`.
3. **LyricsPlus** — 6 mirrors, tried in order.
4. **Unison** — `https://unison.boidu.dev/lyrics`.
5. **Bini** — `https://lyrics-api.binimum.org/` (Apple TTML / LRC
   catalogue).

LRC is parsed with multi-timestamp lines, `[offset:]` and word-stamp
stripping; TTML is parsed for the Bini source. Returns `nil` when
nothing is found. Kugou, Megalobiz, the private LastWave lyrics API,
Musixmatch, Genius and Spotify are not in the chain — they need keys or
private backends (see the header comment in `LyricsProvider.swift`).

## AutoEQ

- Bundled file `Wave/Resources/autoeq_presets.json`: 121 frequencies,
  15 target curves (copied from the Android asset), and 20 real
  per-headphone ParametricEQ profiles from the AutoEq database
  (jaakkopasanen/AutoEq, oratory1990/crinacle).
- One profile: `{ name, source, formFactor ("over-ear" | "in-ear"),
  preampDb, filters: [{ type ("PK" | "LSC" | "HSC"), frequencyHz, gainDb,
  q }] }`.
- A profile becomes 15-band EQ settings by evaluating the summed biquad
  response (RBJ cookbook) at the band frequencies; the preamp becomes
  the settings' preamp. A target curve is sampled instead
  (log-interpolated between the file's frequency points).

## Downloads

- Background `URLSession` (`app.wave.downloads`). Files land in the app
  container under `Downloads/`, named
  `<artist> - <title>.<ext>` (filesystem-sanitised).
- Tags after download: ID3v2.3 for MP3 (TIT2/TPE1/TPE2/TALB/TRCK/TYER,
  USLT, APIC front cover), native Vorbis-comment + PICTURE rewrite for
  FLAC, `AVAssetExportSession` passthrough for M4A. WebM/Opus gets no
  embedded tags (no Matroska writer in this build) — the file still gets
  its name and a `.lrc` sidecar when synced lyrics exist.
- All tag writes go through a validated temp file + atomic replace.

## Last.fm

- `POST https://ws.audioscrobbler.com/2.0/`, `method=track.scrobble`,
  `api_sig` = MD5 of the sorted parameters + secret (per the Last.fm
  auth spec). Scrobbles are queued offline (capped at 200, persisted in
  UserDefaults) and retried on 429 / error 29, with 700 ms spacing
  between writes.
- Auth uses the API key + secret + session key from Settings. The
  `auth.getSession` flow itself is not implemented — the user obtains the
  session key via the desktop auth flow and pastes it in.

## Spotify

- Client-credentials Web API: `/api/token` → `/v1/playlists/{id}` +
  `/tracks` (paginated). Playlist id is parsed from `spotify:playlist:`,
  `open.spotify.com`, `spotify.link` (HEAD redirect) and bare ids.
- Every imported row is matched to a playable YouTube Music track via
  InnerTube search (bounded fan-out of 4, title+artist then title
  alone). A public embed-page fallback (`__NEXT_DATA__`) is used when no
  credentials are configured.
- `likedSongs()` throws `userAuthorizationRequired`: `/v1/me/tracks`
  needs user OAuth, which client credentials cannot mint.

## Navigation (30 destinations)

Splash, Login, Feed, Discover, Genres, Search, Artist, Album, Playlist,
Library, Stats, Settings (+ Audio, Appearance, AutoEQ, Downloads,
Storage, Modules, Excluded Songs, Home Sections), Downloads,
Friend Profile, Jam, Podcasts + Podcast Show, New Releases, Generate,
YouTube Login, Spotify Login, Playlist Import, Lyrics Share — plus the
full player, queue and lyrics sheet. See `Route` in
`Wave/UI/Navigation/Routes.swift`.
