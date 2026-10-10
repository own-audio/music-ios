# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The app, built from own.audio for Subsonic's screens on JellyfinKit: welcome screen and
  sign-in, Home (Shuffle All, Recently Played, Recently Added, Playlists), Library (Artists,
  Albums in seven orders, Songs, Genres, Favorites, Downloads), Playlists with editing,
  Search in the tab bar, mini and full player with queue, lyrics, equalizer, crossfade, sleep
  timer, downloads and offline mode, CarPlay, Czech. The player is player-engine 0.1.0.
- Favorites (a heart, as in Jellyfin) instead of stars; no ratings, which Jellyfin doesn't
  have.
- App icon: the own.audio construction in Jellyfin's purple-to-blue (a placeholder; both
  players' icons are to be rethought so they aren't confused).
- App Store listing text in English and Czech (`AppStore/`), with review notes pointing at
  Jellyfin's public demo server.
- Sign in with Quick Connect: the app shows a code to approve in another Jellyfin app, no
  password typed. A server with several music libraries can show one or all (Settings →
  Servers → Music Library…).
- Instant Mix from a song's menu, an album's menu and an artist's toolbar.
- Playback reporting: start, progress every 15 seconds and stop go to the server, so the
  dashboard shows what is playing and Jellyfin counts plays by its own rules. Plays made
  offline are sent afterwards as played at the time they were heard.
- Smaller streams on mobile data (Settings → Streaming → On Mobile Data: original, 320, 192 or
  128 kbps): the server makes an MP3 as the song plays. Wi-Fi and downloads stay original. A UI
  test plays a 128 kbps stream (`-simulateMobileData` in debug builds).
- Volume leveling from the server's measured loudness (`NormalizationGain`).
- Albums whose tags have no name (or only spaces) show as "Unknown Album".
- UI tests from own.audio for Subsonic, pointed at a Jellyfin server; `scripts/test-servers.sh`
  runs them with the live client tests.
- Implementation plan: feature parity with own.audio for Subsonic, on a hand-written
  Jellyfin client and the shared player-engine package.
- `JellyfinKit`: sign-in by name and password or Quick Connect (the token is kept, never the
  password), server info, music libraries (listings can be limited to one), album artists,
  albums in seven orders (name, artist, newest, recently played, most played, random,
  favorites), album and artist detail, songs page by page, genres, random songs, search,
  instant mix, favorites, playlists (create, add, rename, remove by entry, delete), synced
  lyrics, playback reporting and counted plays, stream and image URLs, sign-out.
  Models follow own.audio for Subsonic's field names so the screens can stay alike.
- Offline support in the client: read answers are kept on disk (`DiskResponseCache`) and come
  back when the network fails or the app is offline (`OfflineSwitch`); writes are refused
  offline with `.offline`.
- `ServerStore`: signed-in servers in one Keychain item, with the chosen library.
- Tests: stubbed client tests; live tests against a real Jellyfin 12.2 server (sign-in,
  browsing, paging, search, instant mix, a favorite and a playlist put back as they were,
  stream and covers, a 128 kbps stream, lyrics, reporting and sign-out, Quick Connect approved
  by a signed-in session). A playlist renamed straight after songs were added to it can keep
  its old name: the server writes the edit out in the background.

### Fixed

- Playlists imported from .m3u files were missing: the list asked the server for audio
  playlists only, and Jellyfin gives imported ones the media type "Unknown". Now every
  playlist but video ones is listed.
- An account with no password (Jellyfin allows them; the public demo has one) couldn't sign in:
  the form wanted a password.
- An address typed without http:// or https:// was tried only as http on port 8096, so a
  server behind https on a public name wasn't found. Now https is tried first, then http on
  8096, then plain http, a few seconds each.
- Turning off playback reporting stopped new reports but not the progress reports of a song
  already playing.
