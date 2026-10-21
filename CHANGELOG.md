# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

Earlier history — own.audio for Subsonic, own.audio for Jellyfin and the player-engine
package, merged into this repository — is in `docs/history/`.

## [Unreleased]

### Concerts (M11)

- The player knows chapters: a concert recorded as one file plays with a chapter where each
  song starts. Next and previous move between its songs — previous restarts a song a few
  seconds in, as for tracks — and past the last song next goes to the next track. The lock
  screen, Live Activity and CarPlay show the song playing, with the concert as its album, and
  keep next enabled while a song follows. `PlayerEngine`: `TrackChapter`, `ChapterNavigation`,
  `setChapters(_:forTrackId:)`, `playChapter(at:)`, `canSkipForward`. Tests:
  `ChapterNavigationTests`, and a real playback in `PlaybackEngineStreamingTests` moving
  between the songs of a concert.

### Tests

- CarPlay unit tests (`UnitTests/CarPlayContentTests`, a new unit-test target hosted by the app):
  the start list, the rows of Downloads (loose songs first, then by name) and Favorites (the songs
  first, then albums), the caps and how a list is built. What CarPlay shows moved out of the scene
  delegate into `CarPlayContent`, as in the books and podcasts apps.

### Fixed

- Settings → Add a Server closed its sheet at once, so no server could be added from Settings:
  the sheet hung on the servers' section, not on the Settings screen. It is shown by Settings
  now. UI test `MusicParityTests.testAddServerSheetStaysOpen` (failed before the fix, on iOS 26.5
  and 27).

### Fixed on iOS 27

- The Search tab had no search field on iOS 27: iOS no longer put the field into the tab by
  itself, so there was nothing to type into (found in the podcasts app). Selecting the tab now
  opens the field, with the keyboard (`tabViewSearchActivation(.searchTabSelection)`), on
  iOS 26 as well.

### Settings the same in all three apps

- The servers are listed in Settings, as in the podcasts app: a tap opens the server's page, a
  swipe removes one after asking ("Remove ‹name›?"), and the selected server has a checkmark.
  The page has **Use This Server**, **Name** (rename), Family and Devices for own.audio (moved
  off the Settings screen), Music Library… for Jellyfin, and **Remove Server** at the bottom.
  The Servers screen and the long-press menu on its rows are gone.
- Settings in the same order as the other apps: Downloads (Offline Mode, Download on Wi-Fi
  Only, Keep at Most, Whole Library When Offline), Streaming, …, About (Version, Source Code and
  Licence, Privacy, Logs, and the same footer).
- Czech: "Úsporný" for Saver and "Odebrat ‹name›?" for removing a server, as in the other apps.
- UI tests follow the new layout; `MusicParityTests.testServerPage` renames and removes a server
  on its page.
- The "Remove ‹name›?" question is asked by the Settings screen itself, as in the podcasts app:
  attached to the servers' section it didn't show on iOS 26.5, and a swipe removed nothing.

### Fixed

- Signing in to own.audio failed with "method_not_allowed" when the address was typed without
  https:// — with Google and Apple as well as with a password — and token refreshes of a server
  saved that way failed too ("session expired"). The app put http:// in front; own.audio
  redirects that to https, iOS repeats a POST after a redirect as a GET, and the server answers
  405. The sign-in also went out unencrypted before the redirect. own.audio is now tried over
  https first (http stays for servers that answer only there, such as a home Navidrome), and
  own.audio servers saved with http:// move to https at launch when the same server answers
  there. UI test `PlaybackSmokeTests.testOwnAudioAddressWithoutScheme` (failed before the fix).
- The Apple and Google buttons stayed hidden when the check for the server's sign-in options
  got no answer in 6 s, as on a slow phone connection, with nothing said. The check now tries
  once more with more time and logs a failure (Settings → Logs), and own.audio's hosted
  addresses show the Google button even without an answer. `MusicParityTests` also checks the
  web app's address typed with https://.
- Logs in Settings → About has the accent colour of the links beside it.
- No pink on the server list and server page: the buttons there (Check Now, Sign In Again, Add
  Address, Update Now, Add Server) take the text colour. The app's pink read as red beside the
  status lines; red is left for removing and for a refused sign-in.
- A streamed song could end early and the next one start, reported about 30 s into a FLAC
  from own.audio's canary on an iPhone. The download and the decoding were one loop: with two
  minutes decoded ahead the player stopped reading, so the connection sat idle and the request
  timed out after 15 s. The download now goes into the cache file at full speed and the decoder
  reads it from there at its own pace (`DownloadRelay` in `StreamingTrackSource`). Not
  reproduced in the simulator, whose network stack buffers more than a phone's. Tests:
  `PlaybackEngineStreamingTests.longStreamDownloadsWhileDecodingWaits` (fails on the old code),
  UI test `PlaybackSmokeTests.testLongSongPlaysPastHalfAMinute` (`SERVER_SONG` starts at a named
  song); the UI tests also scroll to a named album far down the grid.

### Parity with the books and podcasts apps

- The app's own colour: music pink from the family's design tokens (`#D63A6A`, `#FF6482` in dark),
  in the AccentColor asset, which was empty — the app showed the system blue, close to the podcasts
  app's.
- Apple and Google sign-in show only for an own.audio server that takes them, asked 600 ms after the
  address stops changing, as in the other apps; before, both always showed and failed afterwards.
- A Privacy link in Settings → About, as in the other apps.
- UI tests (`MusicParityTests`): the sign-in buttons follow the server; the Privacy link is there.
- Sleep timer: **End of Track** in the sleep sheet, and the timer on the cover (time left, or "End
  of track"), as in the other apps. Stopping at the end of a track works with gapless chaining —
  the next track is cued but stays paused — and crossfade doesn't start while it is set.
- After a relaunch the mini player shows the queue from before, at its track and position, paused;
  a tap plays it from there. Kept in `last-queue.json` (Application Support), written when the
  track changes, playback pauses or the app goes to the background.
- Tests: `PlaybackEngineStreamingTests.sleepAtEndOfTrack`; UI test
  `PlaybackSmokeTests.testSleepBadgeAndLastQueueAfterRelaunch`.
- UI tests open iOS 26's folded tab bar: with Search selected, the other tabs fold into one button,
  and the misuse test's fast tab switching couldn't find Home on any server.
- Downloads go through a background `URLSession`, as in the books and podcasts apps: a song keeps
  downloading with the app in the background or killed, and iOS wakes the app to hand the session
  the next ones (two at a time, so signed links are fresh). Interrupted songs resume from where
  they stopped. Before, downloads stopped with the app and started over on the next launch.
- **Download on Wi-Fi Only** (on by default) and **Keep at Most** (1–50 GB or no limit) in
  Settings. Over the limit, the songs not played for longest go first, never the one playing;
  `EvictionPolicy` is copied from the podcasts app into `MusicLibrary`, with its tests and one for
  songs.
- UI test `MusicParityTests.testDownloadSettings`: the default, the choice, and both kept across a
  relaunch.
- **Devices** in Settings for an own.audio server: the account's signed-in devices, this iPhone
  first and marked, swipe to sign one out, Sign Out Everywhere. `DevicesView` is copied from the
  books app, with the sessions calls (`AccountSession` in OwnAudioKit, `DeviceSession` in
  MusicLibrary). UI test `PlaybackSmokeTests.testDevices` (own.audio only).
- **Recently Played widget** (small and medium): where you left off, then the albums played last
  on the active server, from a snapshot the app keeps in the App Group
  (`group.audio.own.musicplayer`); a tap plays it. Copied from the podcasts app's Up Next widget.
- **Live Activity** on the lock screen and in the Dynamic Island: cover, song, artist, how far, and
  previous / play-pause / next buttons that work without opening the app. Copied from the podcasts
  app; one activity follows the queue from song to song.
- **Siri and Shortcuts**: "Continue listening in own.music", "Play ‹playlist› in own.music",
  "Play the album ‹album› in own.music", with Czech phrases.
- Links `ownmusic://resume`, `ownmusic://play/album/<id>`, `ownmusic://play/playlist/<id>` and
  `ownmusic://player`, which the widget and the Live Activity use. UI test
  `PlaybackSmokeTests.testResumeLink`.
- The widget extension (`OwnAudioMusicWidgets`) and the App Group need the group on both App IDs
  in the developer account before a TestFlight build signs.
- **Play Next** and **Add to Queue** on every song (long press and the ••• menu) and on an album;
  with nothing playing they play at once. A song already in the queue moves rather than playing
  twice. In the queue sheet, drag to reorder and swipe to remove (Edit for the handles), as in the
  podcasts app's Up Next.
- Engine: `playNext`, `addToQueue`, `moveUpcoming`, `removeUpcoming`. When the track after this
  one changes and the old one is already chained for gapless playback, the current track is
  scheduled again from where it is, which chains the new one. Shuffle and repeat changes go the
  same way; before, the old next track still played.
- Tests: `PlayQueueEditingTests` (6), `PlaybackEngineStreamingTests.playNextAfterChain`, UI test
  `PlaybackSmokeTests.testPlayNextAndQueueEditing`.
- **Logs** in Settings → About: what the app logged this run, to read and to share as a text file
  with a bug report; nothing leaves the phone otherwise. Copied from the books app.
- **Background refresh** (`BGAppRefreshTask`, about hourly when iOS allows): the library copies,
  waiting plays and edits, and the widget. Copied from the books app.
- UI tests start through `launchChecked()` (copied from the books app): iOS can hand a test a
  prewarmed process without its launch arguments, which then ran in the simulator's language or
  without the reset; the first screen is checked and the launch tried again. `-uiTestReset` also
  resets the settings (Offline Mode, mobile data, downloads, player), as in the other apps.
- UI test `MusicParityTests.testNewSettingsInCzechAtLargestText`: the new Settings rows translated
  and reachable at the largest text size. The parity table and its statistics are updated
  (`docs/ios-apps-feature-parity.md`: Music 86 %, Books 85 %, Podcasts 78 %).

### Changed

- One repository for one app, **own.audio Music**: the Subsonic app, the Jellyfin app's client
  (`Packages/JellyfinKit`) and the playback engine (`Packages/PlayerEngine`, again a local
  package) with their histories. The app target is `OwnAudioMusic`, bundle id
  `audio.own.musicplayer`, home screen name "own.music". For now it is still the Subsonic app;
  Jellyfin and own.audio follow.
- A library layer over the servers (`Packages/MusicLibrary`): one set of models (artist, album,
  song, playlist, genre, lyrics), a `MusicSource` interface with what each server can do, and an
  adapter per kind (Subsonic, Jellyfin). Every screen works through it; a feature a server
  lacks is hidden — ratings and "top rated" only where the server has ratings, Instant Mix only
  where it has one.
- `Packages/ServerSupport`: the saved-answers cache, the offline switch and the play-counting
  rule, shared by both server clients instead of copied.
- One Keychain store for every kind of server, with a server's kind, address, sign-in and
  chosen music library.

- Next and previous grey out where the queue ends, as in Apple Music: next on the last song
  (in the mini player too, which used to hide it), previous on the first song until it is
  three seconds in, from when it restarts the song. A swipe on the cover does nothing there
  either, and the lock screen follows.

- What goes wrong is logged with its cause (Console, or the UI tests' app log): failed
  requests with their path and status or error, never the query, which can carry a sign-in;
  answers that couldn't be read and why; every error shown on screen; and each load, skip and
  stop of the player. The server clients used to reduce all of it to "network" or "decoding".

### Added

- Every download says which server it came from.
- A Downloads tab: the albums, playlists and songs on this iPhone, one tap from anywhere (it
  was inside Library before).
- CarPlay: the app carries Apple's CarPlay audio entitlement (granted 2026-10-16), so the
  CarPlay screens built earlier show in a car: Recently Played, Recently Added, Playlists,
  Artists, Favorites and Downloads, and Now Playing.

- Misuse UI tests (`UITests/MisuseTests.swift`), against every kind of server: wrong
  sign-ins, the player hammered, ✕ while a song loads, screens left before they load and odd
  searches, background, no network, relaunch and the server removed mid-song, the app killed
  mid-download.
- `scripts/test-servers.sh` keeps everything a run leaves: the whole xcodebuild log, a result
  bundle per run, the app's own log, crash reports and screenshots of failures, with each test
  shown as it runs and a summary with the failure messages. It tests a copy of the code taken
  at its start, builds once before any server, and a failing server no longer ends the run.

- Identify Library, on an own.audio server's page when the server offers it: the server compares
  the songs with MusicBrainz in the background, and the app shows what it proposes by album — to
  review, sure, not found, done. Accept or reject a song (swipe or hold), accept a whole album
  (songs matched to another artist are left out), every sure match at once, another edition of an
  album, or keeping a compilation's song on its own album. A run can be undone or deleted; the
  files on the server never change. Progress comes from the server's `identify` events where it
  sends them, else from a slow poll. A server that charges for it says the price before a run
  starts. `OwnAudioKit` has the calls (`Identify.swift`) and reads a server's `modules`.
- Identify Library is in the Library too, and a run can cover one of the server's music folders
  instead of the whole library. An album's menu has Identify Album, an artist's Identify Artist.
  A song's menu has Undo Identify, which puts it back as its file says; so does swiping an
  accepted song on a run's Done tab.
- When the tags are wrong — "Track 02", a typo, the artist in the title — the search can be
  corrected: a song a run found nothing for, or found wrong, gets Search… / Other Recording…,
  which lists what the server also found, searches MusicBrainz again with your words, or takes a
  pasted musicbrainz.org link. Any song's menu has Identify…, the same for a song on its own
  (own.audio servers from 1.0.0-beta.14). An album's Other Edition… can search again with a
  corrected album or artist (from 1.0.0-beta.15).
- **Covers of the matches** in identify: a proposal's release, each edition and each recording
  show their cover from Cover Art Archive (the release group's when the release has none), so the
  right one is seen at a glance.
- Deleting an identify run started from an album or the Library closes it; before, the sheet
  stayed open on "This run is gone".
- A cover changed on an own.audio server — an identify now brings the release's — shows in the
  app: covers are cached by the image, not only by the album or song, so a new one is fetched.
- Every song row has a **⋯ button** with the same actions as a long press (favorite, rating,
  playlist, identify, download), where people look for them.
- own.audio servers from 1.0.0-beta.7 are signed in to through their own API: the app keeps
  its tokens (refreshed one at a time, rotated tokens saved straight back to the Keychain) and
  the account's Subsonic key, which it fetches with them. Accounts with **two-factor sign-in**
  get a code screen after the password, Apple or Google; the code from an authenticator app or
  a recovery code finishes it. Older own.audio servers, and servers added before this version,
  go on as before.
- **The library on the phone from own.audio's change feed**: the whole library once, then only
  what changed since — refreshed every ten minutes, on mobile data too, as it is small. A first
  feed sync that fails falls back to paging.
- **Smart playlists** on own.audio servers from 1.0.0-beta.13: your own and the server's
  ready-made ones at the top of Playlists. Each is a rule, worked out anew whenever it opens from
  what you have listened to; play it, shuffle it, ask for a new selection, keep it as an ordinary
  playlist. Make or change one in an editor that counts the songs that fit as you go. Shared with
  the family, everyone gets their own selection from it.
- own.audio servers from 1.0.0-beta.11: **playlists, search, random songs, lyrics** and the
  **Recently Played / Most Played** orders go through the server's own API instead of its
  Subsonic one. Removing a song from a playlist goes by its entry, so the right one goes when a
  song is in it twice. Instant Mix is no longer offered for own.audio (the server never had
  songs to pick for it). Offline, the screens work from saved answers as before.
- own.audio servers now go through their own API for **everything the app browses and plays**:
  artists, albums in all eight orders, an album's and artist's songs, all songs, genres,
  favorites, ratings and counted plays. **Streams and downloads** are links the server signs per
  song, asked for when a song starts — the original where the player can decode it, AAC made by
  the server otherwise (Ogg, Opus) or when a lower bitrate is set for mobile data. **Covers and
  artist pictures** are the API's images at the nearest size it makes; their links run out after
  a week or two, so the app keeps covers by id and reads a record again for a fresh link. What
  the API answered is saved, so screens seen once open offline, as they did through the Subsonic
  API.
- **No Subsonic key for own.audio**: signing in to an own.audio server from 1.0.0-beta.7 keeps
  only the API's tokens and the account's email. Servers signed in earlier keep their key, which
  still sends the "now playing" report and lists music folders; without one there is neither,
  as v2 has no word for them yet.
- **Your own pictures** on own.audio servers: Choose Cover… on your songs, Choose Album Cover…
  on an album of yours (its songs take it), Choose Picture… on any artist, and Choose Cover… on
  your playlists. The picture comes from the system's photo picker, which needs no access to the
  whole library, is made smaller (1600 px, JPEG) and uploaded; the app shows it at once. An
  artist's picture chosen this way is kept: the automatic lookup never replaces it.
- An ✕ at the top right of the player stops playback and closes it.
- own.audio servers come first in the server menu and in Settings → Servers.
- **The family on own.audio servers**: Settings → Family lists who is in it, with the family's
  and each member's picture, what the family keeps on the server (music, audiobooks, podcasts)
  and, on a server that charges for storage, the prepaid credit and how long it lasts; an admin invites someone with a code (a QR code, or the share sheet), and anyone can
  join another family with one. Your own songs can be shared with the family or kept to
  yourself from their menu, a whole album's at once, and your playlists from theirs; a shared
  song of yours shows a small people icon. Nothing is shown locked: private only means not
  shared.
- `scripts/app-store-upload.swift` puts the listing on App Store Connect through its API (a key
  in `release.local.env`): name, subtitle, privacy policy, description, keywords, promotional
  text and links per language, and the captioned screenshots for iPhone and iPad, replacing
  what was there. `--dry-run` says what it would do, `--status` how the screenshots were taken.
- App Store screenshots are taken from a server holding only the demo library (as its admin,
  with Navidrome and Jellyfin beside it), and `scripts/marketing-screenshots.swift` puts each on
  the own.audio background with a caption from `AppStore/<language>/captions.json`, at the
  store's sizes. The song search shown is a real one, with its releases' covers.
- The App Store listing (English and Czech) describes the app it is now — Subsonic, Jellyfin
  and own.audio — and a privacy policy (`PRIVACY.md`) says what the app keeps and sends:
  nothing collected, nothing sent beyond the servers you add and a sign-in you choose. The
  screenshots add the Playlists tab.
- **A new icon**: the own.audio family figures around the note in their own colours, the
  note in red, and no `</>` at the bottom. The welcome screen and the server list show it too.
- **Sign In Again** on a server's detail screen (Settings → Servers → ⓘ), with a warning when
  the server stopped accepting the saved sign-in — a changed password, an ended session, a
  demo server that resets every night. With a password, or with Apple or Google where the
  own.audio server offers them. The server keeps its downloads, library on the phone and
  addresses; own.audio's two-factor code is asked for as when adding a server.
- **Check Now** shows that it is checking and then what it found, with the time: the server
  answers and accepts the sign-in, refuses it, or does not answer. For own.audio it checks the
  API's sign-in as well as the Subsonic key.
- Each server shows **what it is and how the app talks to it** — own.audio's logo,
  Jellyfin's or OpenSubsonic's, without a background, in the server list, on its detail
  screen and in the server menu on Home, and "own.audio · own API", "own.audio · Subsonic API" (added the older way: sign in again to switch), "Subsonic
  API" or "Jellyfin API" in the list and on the detail screen.
- **Live updates from own.audio** (servers from 1.0.0-beta.7, signed in through the new API):
  while the app is on screen, the server says when the library or the listener's favorites and
  ratings change, and the library on the phone catches up within seconds — a favorite set on
  another device shows without waiting for the next sync.
- Changes made offline reach own.audio in **one request** (`/sync/push`), each with the time it
  was made: favorites, ratings, and plays with how long they were heard. A play sent twice —
  the answer lost on the way — counts once. Playlist edits, and other servers, go one at a time
  as before. Ratings made offline now remember whether they were for a song or an album.
- `Packages/OwnAudioKit`: a client for own.audio's own API (`/api/v2`, servers from
  1.0.0-beta.7), Foundation only like the other two. Discovery, sign-in through the OAuth token
  endpoint (password, two-factor, a provider's id token), refresh tokens that rotate — one
  refresh at a time, since the server signs a device out when a used refresh token comes back —,
  problem-details errors, cursor pages, the catalogue, favorites, ratings, progress, plays,
  `playback-info`, the change feed and the streamed snapshot.
- **Jellyfin**, next to Subsonic: adding a server finds out what it is (Jellyfin's public info
  first, then a Subsonic ping); sign in with a password or Quick Connect (Jellyfin); a
  music-library choice per Jellyfin server (Settings → Servers → Music Library…); Instant Mix
  from a song's and an album's menu; playback reporting the way Jellyfin expects (start,
  progress, stop; plays it never heard about are sent afterwards); smaller streams on mobile
  data where the server makes them (Settings → Streaming); volume leveling from Jellyfin's
  measured loudness.
- Accounts with no password can sign in (Jellyfin allows them).
- Albums with no name in their tags show as "Unknown Album".
- `scripts/test-servers.sh` runs the live client tests and the UI tests against Navidrome,
  own.audio and Jellyfin; the UI tests read `TEST_RUNNER_SERVER_*`. New UI test: a 128 kbps
  stream on (simulated) mobile data plays.
- **Several addresses per server, chosen automatically.** A server can be known by its home
  address, a VPN address and its public name; after every network change (Wi-Fi to mobile
  data, a VPN coming up) and whenever the server stops answering, the app tries them all at
  once and keeps the fastest that answers as the same server — Jellyfin and own.audio servers
  give an identity, so an address that answers as another server is never used. Jellyfin and
  own.audio servers name their own addresses (Jellyfin its home address, own.audio its whole
  list); for Subsonic servers they are added by hand. Plain http only to home-network
  addresses or ones you entered. What worked is remembered per network, so the next start is
  instant. Settings → Servers → ⓘ shows the address in use and lets you add addresses or fix
  one. No location permission needed.
- own.audio servers are recognised as such when added (they answer own.audio's discovery
  request): their identity and addresses come with them.
- **own.audio accounts**: sign in with the account's email and password; the app fetches the
  account's Subsonic key itself (the key still works too).
- **Sign in with Apple** for own.audio servers that offer it (the server lists the app's bundle
  id in `AUTH__APPLE__CLIENT_IDS`): Apple's identity token becomes a session on the server, and
  the app fetches the account's Subsonic key with it; only the key is kept.
- Search works on iOS 27: the system draws the search tab as an ordinary tab there and kept its
  field hidden, so there was nothing to type into. The field is always shown on iOS 27; tabs
  switch through an explicit selection.
- Subsonic servers see the app as "own.audio Music" (the `c` parameter), not "own.audio-subsonic".
- **Continue with Google** for own.audio servers that offer it, without Google's SDK: Google's
  page in the system sign-in sheet with PKCE, the code exchanged for an ID token, which the
  server verifies (its `AUTH__GOOGLE__CLIENT_IDS` must list this app's iOS client).
- The address people know from the browser works for the hosted service: `own.audio` and
  `app.own.audio` lead to `api.own.audio`, `app-canary.own.audio` to `api-canary.own.audio`.
- TestFlight and development builds offer **own.audio canary** as a one-tap address, for testing
  against the server version that runs there first. The App Store build doesn't list it.
- **Try the Demo Library** on the first screen: signs in to the public own.audio demo with the
  account it offers, for anyone without a server yet. The first screen says own.audio Music.
- **On mobile data: Original, Saver or Downloaded Only** (Settings → Streaming), with the
  Saver quality (320, 192 or 128 kbps). Saver asks Subsonic servers for a smaller MP3
  (`maxBitRate`, `format=mp3`) as Jellyfin already did; Downloaded Only plays just what is on
  the phone and says so in the banner, with a button to stream anyway.
- **The library on the phone.** Each server's catalogue — artists, albums, songs, playlists,
  without the music — is synced in the background (on adding a server, at launch and when the
  network comes back; refreshed after six hours on Wi-Fi, never in Low Data Mode). Offline, an
  album never opened before still opens with all its songs, the ones not downloaded greyed
  out. Settings → Whole Library When Offline lists everything on the server offline, not only
  the downloads. Settings → Servers → ⓘ shows the count, when it was updated, and Update Now.
- A server reinstalled from scratch (or a demo that resets nightly) is still found at the
  public https address it was added with, and its new identity is taken over; home and VPN
  addresses must still answer as the same server.
- iOS Low Data Mode caps streams at 128 kbps where the server makes smaller streams.
- Favorites, ratings and songs added to a playlist while offline are kept and sent when the
  server can be reached again, in order; the screens show them at once.
- Saved server answers are filed under the server, not the address, so switching addresses
  keeps them.
- UI test: the server's connection screen ends up connected (on Jellyfin from the home
  network: the home address the server named).

### Fixed

- Streaming a long track — an audiobook on a Subsonic server, say — stuttered and could end
  the app: every decoded second was kept in memory (a stereo hour is over a gigabyte) and a
  network that fell behind played gaps. The engine now keeps about two minutes decoded ahead
  and fetches as playback makes room; when the network falls behind it holds, shown as loading,
  until eight seconds are in hand; and the bytes streamed are kept in the cache as they pass,
  so a seek within the track or a second listen plays from disk.
- CarPlay said why a list didn't load (no signal, server error) instead of showing it empty,
  and a tap on an album with no signal no longer does nothing; lists keep to the car's own
  limit; a server added or chosen on the phone shows in the car at once; the title is the
  app's name, not "subsonic".
- A seek in a song still streaming played the next song instead, after "Could not play this
  track": the seek cancels the stream to play from the file, and the cancelled download was
  taken for a failure.
- FLAC that opens with digital silence wouldn't play while it streamed: it sat on "loading"
  until the whole file had come down, half a minute or more. Two Core Audio limits met there:
  its stream parser cuts FLAC at the sync code alone, which real music also holds inside its
  frames (57 times in the first 3 MB of one album track), and its decoder takes a frame of
  silence in FLAC's shortest form for bad data. FLAC frames are now cut by our own framer, a
  frame ending only where its CRC-16 holds, and a rejected frame plays as the silence it is.
  A decoder that takes half a megabyte and gives no audio is given up for the whole file, as
  any other decoding failure already was, instead of the player waiting for good.
- Opening the app stopped what another app was playing, before anything was played: the
  audio session became active at launch. It does so now when playback starts.

- With crossfade on, a song skipped to played ten seconds or so and gave way to the next: it
  streams (only songs in sequence are fetched ahead), and once playback caught up with what had
  arrived, the end of the data so far was taken for the end of the song. The fade now waits
  until the whole song has arrived. A fetch of the next song still running at a skip no longer
  chains anything onto the new song, and a song played from a file fetches its successor too.
- Artists on an own.audio server all said "0 albums": its API gives no count. The count comes
  from the library on the phone now, and isn't shown where that isn't there; genres the same.
- Moving the position in the player made it flash: the format, the cover and the times reset
  while the song reloaded, and the bar jumped back before jumping forward. They now stay, and
  the bar holds where it was dropped. Only the position and times redraw as the song plays, not
  the whole player with its blurred cover.
- Identify was offered on every song, and failed on anyone else's: the server identifies only
  the owner's. It is offered now on your own songs, and on albums and artists you have songs of.
- Searching MusicBrainz for a song kept the album from its tags, so correcting the title and
  artist found nothing when the album was wrong too; with nothing on that album, the search now
  goes on without it, and says so. Each search field has a ✕ to empty it.
- Another family member's playlist on an own.audio server said "by" and a long id; it says
  their name now, as the family calls them.
- VoiceOver read an album's song rows and their ⋯ buttons under the same name, so the ⋯
  button could not be told from its row (UI tests downloaded the wrong song).
- Playing a streamed song whose format differs from the player's — a 22 kHz mono FLAC — ended
  the app; the stream is now converted, as a downloaded file already was.
