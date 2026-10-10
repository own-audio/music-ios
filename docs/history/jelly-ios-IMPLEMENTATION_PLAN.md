# Implementation plan

A native, open-source iPhone and iPad music player for Jellyfin. Swift 6, SwiftUI, iOS 18+.
App Store name "own.audio for Jellyfin", home screen "own.jelly". Same features as
[own.audio for Subsonic](https://github.com/own-audio/subsonic-ios), built the same way.

## Shape

- **`player-engine`** — the playback engine moves out of subsonic-ios into its own public
  Swift package (`own-audio/player-engine`, MPL-2.0). Both apps depend on it by version, so a
  playback fix is made once. It knows tracks by opaque id and nothing about servers.
- **`Packages/JellyfinKit`** — this repo's protocol client, Foundation only, written by hand
  against the REST API rather than generated from OpenAPI: a music player needs about thirty
  endpoints, and a generated client would be most of the code and hard to read.
- **The app** — copied from subsonic-ios and adapted. Screens, offline mode, downloads,
  CarPlay, localization and the test setup carry over almost unchanged; what differs is below.

## Where Jellyfin differs from Subsonic

| | Subsonic app | This app |
|---|---|---|
| Sign-in | user + password, token per request | `AuthenticateByName` → access token kept in the Keychain (no password stored); Quick Connect as a second way |
| Libraries | one library | a server can have several music libraries; pick one or all |
| Favorites | star | `IsFavorite` |
| Ratings 1–5 | yes | none in Jellyfin; left out |
| Scrobbling | `scrobble` | playback reporting (`/Sessions/Playing`, `/Progress`, `/Stopped`): play counts, resume, "now playing" on the dashboard; plugins forward to Last.fm / ListenBrainz |
| Volume leveling | ReplayGain tags | `NormalizationGain` (the server measures it when the library has it enabled) |
| Lyrics | `getLyricsBySongId` | `/Audio/{id}/Lyrics` (synced LRC and plain) |
| Streaming | original file | original file (`/Audio/{id}/stream?static=true`); optional transcoding on mobile data via `/universal` |
| Covers | `getCoverArt` | `/Items/{id}/Images/Primary`, no auth needed |
| Artists | artist | album artist list, with "all artists" as an option |
| Instant mix | — | `/Items/{id}/InstantMix`, a Jellyfin extra worth having |

## Phases

- [x] **P0: Shared engine.** Create `own-audio/player-engine` from subsonic-ios's
  `Packages/PlayerEngine` with its history, tag 0.1.0, switch subsonic-ios to it and check its
  tests and UI tests still pass. XcodeGen skeleton for this app; launches on the simulator.
  Engine part done 2026-10-09: 0.1.0 with products `MusicEngine` and `PlayerCore`; subsonic-ios
  uses it and passes all its tests on both servers. App skeleton done the same day.
- [x] **P1: JellyfinKit.** 12 stubbed tests, 8 live tests passing against Jellyfin 12.2
  (2026-10-09). Auth (`AuthenticateByName`, Quick Connect, the
  `Authorization: MediaBrowser …` header with a stable device id), public server info, user
  views, album artists, albums (sorts: name, artist, date added, played, random, favorites),
  album and playlist items, songs (paged), genres, search, favorites, playlists (create,
  rename, add, remove, delete), lyrics, instant mix, stream and image URLs. Stubbed tests plus
  live tests gated on `JELLYFIN_HOST/USER/PASSWORD`.
- [x] **P2: Servers.** Add (address, user, password or Quick Connect), check, rename, remove,
  several at once; library picker when a server has more than one music library.
- [x] **P3: Library and player.** All five UI tests from subsonic-ios pass against Jellyfin
  12.2 (2026-10-09). The subsonic-ios screens on JellyfinKit: Home, Library
  (Artists, Albums, Songs, Genres, Favorites), Playlists, Search in the tab bar; mini and full
  player, queue, AirPlay; UI smoke test.
- [x] **P4: Server features.** Favorites, playlist editing, playback reporting with an
  offline queue, instant mix from a song, album or artist.
- [x] **P5: Downloads and offline mode.** As in subsonic-ios: downloads per song, album and
  playlist; offline mode with the library from the downloads and saved server answers; UI
  test for a partly downloaded album.
- [x] **P6: Extras.** Lyrics, volume leveling from `NormalizationGain`, EQ, crossfade, sleep
  timer, mobile-data quality setting (transcode or original).
- [ ] **P7: CarPlay.** Same templates as subsonic-ios.
- [~] **P8: Release.** Done: icon (placeholder, to be rethought), App Store text, review notes
  (Jellyfin's demo server). Privacy section on own.audio, first TestFlight build, public
  repository (2026-10-09). To do: screenshots, Jellyfin's clients page. Was: iPad, Czech, large text, icon (the own.audio ring with the open-source
  mark, Jellyfin-coloured), App Store text and screenshots, privacy policy section on
  own.audio, TestFlight, public repository, listing on Jellyfin's clients page.

## Test server

A real Jellyfin 12.2 server with a large music library (about 9 400 songs, 500 albums,
30 playlists; mostly MP3, some FLAC). Its address and credentials live in the gitignored
`test-servers.local.env`, never in this repo. Found while planning: it has no
`NormalizationGain` yet (volume leveling needs the library option on), and the
`api_key` / `ApiKey` query parameter works for streams while `/universal` wants the header.
