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

