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
