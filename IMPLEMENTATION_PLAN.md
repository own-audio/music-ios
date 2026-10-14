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
- [x] **M3: own.audio.** Done 2026-10-10 for email and password, plus a demo button; Google
  sign-in later (needs an OAuth client for the new bundle id). Sign in with an own.audio account (email and password, Google); the
  app fetches the Subsonic key itself. Library through the Subsonic source; own.audio's own API
  for what Subsonic lacks, as the server grows it.
- [x] **M4: Data and quality.** Done 2026-10-10; seeking in a transcoded stream with
  `timeOffset` is still open (scrubbing waits for the song to arrive). "On mobile data: Original / Saver / Downloaded only"; iOS Low
  Data Mode; Subsonic `maxBitRate`/`format` where the server transcodes; changes made offline
  (favorites, ratings, playlist edits) queued and sent later.
- [x] **M5: Several addresses per server.** Done 2026-10-10 (needs own.audio server 1.0.0-beta.3
  for own.audio's list). Learn a server's addresses (Jellyfin's
  `LocalAddress`; own.audio once its server lists them; by hand for Subsonic), race them on
  every network change, accept only the same server id, remember per network.
- [x] **M6: Catalogue on the phone.** First pass done 2026-10-10: full sync by paging (no
  change feed yet — the server needs one), whole library offline as a setting. Background sync of the whole catalogue so browsing is
  instant and complete offline; uses a server change feed where there is one.
- [ ] **M7: Release.** Icon, App Store text, screenshots, privacy policy section, TestFlight
  under the new bundle id; Jellyfin's and Navidrome's client pages.
- [x] **M8: own.audio on its own API.** own.audio servers from 1.0.0-beta.7 speak `/api/v2`
  (draft until this app ships on it). In steps:
  - [x] **M8a — OwnAudioKit** (2026-10-11; unit tests and live tests against a beta.7 server): a client for `/api/v2`, Foundation only, beside SubsonicKit and
    JellyfinKit: discovery (`/.well-known/own-audio`), the token endpoint (password, refresh with
    rotation, two-factor, device code), problem details, cursor pages, the catalogue, the
    listener's state, `playback-info`, the change feed and snapshot.
  - [x] **M8b — the own.audio source on v2** (2026-10-11; favorites, ratings and plays stay on Subsonic, which writes the same records, so there was nothing to gain moving them yet): sign-in through the token endpoint (tokens in the
    Keychain); favorites, ratings, plays and streaming through v2; the catalogue on the phone
    from the snapshot and the change feed instead of paging. What v2 does not offer yet
    (playlists, search, random songs, instant mix, lyrics, play-count orders) still goes
    through the server's Subsonic API, which uses the same ids.
  - [x] **M8c — offline changes and live updates** (2026-10-11; live tests against a beta.8
    server): what was changed offline goes in one `/sync/push` (favorites, ratings with their
    kind, plays with the time heard; playlist edits stay one call each, v2 has no playlists
    yet); while on screen the active server's `/events` stream triggers a change-feed sync.
  - [x] **M8d — the rest of what v2 offers** (2026-10-13; needs server 1.0.0-beta.11): playlists
    (list, open, make, rename, delete, add, remove by entry id), search, random songs (by genre),
    lyrics, and the Recently Played / Most Played album orders go through `/api/v2`. Favorites and
    ratings shown with those answers come from the change feed (`ListenerState`), as the API's
    records don't carry them. Instant mix is hidden for own.audio: the server has nothing to pick
    similar songs from. Offline, or with the API's sign-in refused, the Subsonic API answers (its
    saved answers keep the screens working).
  - [x] **M8e — browsing and media** (2026-10-14; live tests against a beta.18 server): artists,
    albums (all eight orders: name and newest as cursor pages behind the app's offsets, by
    artist and random from the whole list, favorites and highest rated from the listener's
    state), an album's and artist's songs, all songs, genres, favorites, ratings and counted
    plays through v2. Streams and downloads through `playback-info` (the source's URL methods
    became async); covers and artist pictures from the records' signed image links, kept with
    each id's kind in a `RecordIndex` and read again once a link runs out. `OwnAudioClient`
    saves read answers (`AnswerCache`), so offline works from the API's own answers. Left on
    the Subsonic API: the "now playing" report and music folders, which v2 has no word for.
  - [x] **M8f — no Subsonic key** (2026-10-14): a sign-in through the API keeps only its
    tokens and the account's email (`ServerAuth.ownAudio`'s key is optional). Servers signed in
    earlier keep their key for the "now playing" report, music folders, and as the fallback
    while the API's sign-in is refused; without one there is no "now playing" report and no
    music-folder choice for own.audio until v2 has them.
- [x] **M10: The household** (2026-10-14, own.audio servers signed in through the API): the
  household's members, invitations (code, QR, share sheet) for admins, joining with a code;
  sharing one's own songs, albums and playlists, with a people icon on one's shared songs —
  never a lock. `HouseholdSource` in MusicLibrary; `Song.sharing`, `Playlist.isShared`.
- [x] **M9: Smart playlists.** Done 2026-10-13 (needs own.audio server 1.0.0-beta.13, the API's
  V11): on Playlists, the account's smart playlists and the server's ready-made ones (Forgotten
  Favorites, New in the Library, Back in Rotation, What the Family Plays, Genre Station with a
  genre to pick). Opening one shows what it holds now, for this listener — a new draw each time
  — to play or shuffle. An editor for the rule (genres, favorites only, rating, not played for,
  added in, played by others, tempo, energy, length in songs or minutes, order, energy over
  time, artist spacing) counts the songs that fit as it changes. A smart playlist can be shared
  with the household (each member gets their own selection), saved as an ordinary playlist, or
  deleted. Servers without them (Subsonic, Jellyfin, older own.audio) show none.
- Later: Plex as a fourth server (official API since 2025), podcasts tab where the server has
  podcasts, CarPlay check.
- Later: Ampache (tried 8.2.2 on 2026-10-11): its Subsonic API refuses token sign-in (`t`+`s`,
  error 40) and takes only the password (`p=`) or an OpenSubsonic API key
  (`apiKeyAuthentication`), so the app can't sign in to it yet.

## Test servers

A Navidrome, a Jellyfin and the own.audio demo server; addresses and credentials in the
gitignored `test-servers.local.env`, never in this repository.
