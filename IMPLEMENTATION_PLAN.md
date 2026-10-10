# Implementation plan

**own.audio Music** — one native, open-source music player for iPhone and iPad that plays from
**own.audio, Subsonic/OpenSubsonic servers (Navidrome, Gonic, Airsonic, LMS, Ampache…) and
Jellyfin**, side by side. Swift 6, SwiftUI, iOS 18+. MPL-2.0.

It replaces two apps that were built separately in October 2026 — own.audio for Subsonic and
own.audio for Jellyfin — and brings their shared playback engine back into this repository.
Their histories are merged here; their plans and changelogs are in `docs/history/`.

## Principles

- **One app, many servers.** People want one music app whatever their server; someone moving
  between servers keeps the app. A feature a server lacks is hidden, not broken.
- **Robust by default, simple to change.** Automatic connection and quality choices; one visible
  setting ("On mobile data: Original / Saver / Downloaded only"); a manual mode for those who
  want it. A player that doesn't play is the worst outcome.
- **Small and native.** No third-party dependencies without a strong reason, server clients
  written by hand, system decoders only (no VLC/FFmpeg — servers transcode what iOS can't
  play), no cross-platform frameworks. Watch the app size on every release (~2.6 MB today).
- **Local player, server as the brain**: the catalogue on the phone, downloads, changes made
  offline queued and synced later.
- own.audio is one server among the others here, with extras where its server offers them.

## Layout

- `App/OwnAudioMusic/` — the app.
- `Packages/SubsonicKit/` — Subsonic/OpenSubsonic client.
- `Packages/JellyfinKit/` — Jellyfin client.
- `Packages/PlayerEngine/` — the engine: `MusicEngine` (gapless AVAudioEngine player, streaming
  decoder, EQ) and `PlayerCore` (Now Playing, sleep timer, resume points, file cache).
- `UITests/` — end-to-end tests against real servers.

## Phases

- [x] **M0: One repository.** Histories of subsonic-ios, jelly-ios and player-engine merged; the
  engine back as a local package; JellyfinKit beside SubsonicKit; the Subsonic app renamed
  `OwnAudioMusic` (bundle `audio.own.musicplayer`, home screen "own.music"). Builds; nothing
  user-visible changed yet.
- [x] **M1: A library layer over the servers.** One set of models (artist, album, song,
  playlist, genre, lyrics) and a `MusicSource` interface with what a server can do
  (capabilities: ratings, instant mix, podcasts, lower bitrate, …). A Subsonic source on
  SubsonicKit; every screen moves onto the layer. All of the Subsonic app's UI tests pass.
- [x] **M2: Jellyfin.** All UI tests pass against Navidrome, own.audio and Jellyfin
  (2026-10-10); the old repositories are archived with a pointer here. A Jellyfin source on JellyfinKit, with what the Jellyfin app had:
  Quick Connect, the music-library picker, favorites as hearts, instant mix, playback
  reporting, smaller streams on mobile data. Adding a server finds out what it is (Jellyfin's
  public info, else a Subsonic ping). All of the Jellyfin app's UI tests pass against
  Jellyfin; the Subsonic ones still pass. The two old repositories are archived with a
  pointer here.
- [ ] **M3: own.audio.** Sign in with an own.audio account (email and password, Google); the
  app fetches the Subsonic key itself. Library through the Subsonic source; own.audio's own API
  for what Subsonic lacks, as the server grows it.
- [ ] **M4: Data and quality.** "On mobile data: Original / Saver / Downloaded only"; iOS Low
  Data Mode; Subsonic `maxBitRate`/`format` where the server transcodes; changes made offline
  (favorites, ratings, playlist edits) queued and sent later.
- [x] **M5: Several addresses per server.** Done 2026-10-10 (needs own.audio server 1.0.0-beta.3
  for own.audio's list). Learn a server's addresses (Jellyfin's
  `LocalAddress`; own.audio once its server lists them; by hand for Subsonic), race them on
  every network change, accept only the same server id, remember per network.
- [ ] **M6: Catalogue on the phone.** Background sync of the whole catalogue so browsing is
  instant and complete offline; uses a server change feed where there is one.
- [ ] **M7: Release.** Icon, App Store text, screenshots, privacy policy section, TestFlight
  under the new bundle id; Jellyfin's and Navidrome's client pages.
- Later: Plex as a fourth server (official API since 2025), podcasts tab where the server has
  podcasts, CarPlay check.

## Test servers

A Navidrome, a Jellyfin and the own.audio demo server; addresses and credentials in the
gitignored `test-servers.local.env`, never in this repository.
