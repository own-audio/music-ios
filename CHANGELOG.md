# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

Earlier history — own.audio for Subsonic, own.audio for Jellyfin and the player-engine
package, merged into this repository — is in `docs/history/`.

## [Unreleased]

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

### Added

- Identify Library, on an own.audio server's page when the server offers it: the server compares
  the songs with MusicBrainz in the background, and the app shows what it proposes by album — to
  review, sure, not found, done. Accept or reject a song (swipe or hold), accept a whole album
  (songs matched to another artist are left out), every sure match at once, another edition of an
  album, or keeping a compilation's song on its own album. A run can be undone or deleted; the
  files on the server never change. Progress comes from the server's `identify` events where it
  sends them, else from a slow poll. A server that charges for it says the price before a run
  starts. `OwnAudioKit` has the calls (`Identify.swift`) and reads a server's `modules`.
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
  the household, everyone gets their own selection from it.
- own.audio servers from 1.0.0-beta.11: **playlists, search, random songs, lyrics** and the
  **Recently Played / Most Played** orders go through the server's own API instead of its
  Subsonic one. Removing a song from a playlist goes by its entry, so the right one goes when a
  song is in it twice. Instant Mix is no longer offered for own.audio (the server never had
  songs to pick for it). Offline, the screens work from saved answers as before.
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

