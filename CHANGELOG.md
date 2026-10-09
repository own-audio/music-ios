# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-09

First release, moved out of [subsonic-ios](https://github.com/own-audio/subsonic-ios)
(`Packages/PlayerEngine`) with its history, so the Subsonic and Jellyfin apps share one engine.

### Changed

- Split into two products: `MusicEngine` (the player, queue, decoder and streaming,
  equalizer, spectrum, ReplayGain) and `PlayerCore` (Now Playing, sleep timer, resume points,
  file cache, payload check). `MusicEngine` re-exports `PlayerCore`, so apps import one module.
- `TrackFileCache.stream(…)` lives in `MusicEngine` (it needs the decoder);
  `resolveRemoteURL(trackId:)` and `urlSession` are public for it.

### Included from subsonic-ios

- Gapless playback and crossfade on `AVAudioEngine`; progressive streaming with an
  `AudioFileStream` decoder, falling back to a full download for M4A files with a trailing
  `moov` atom.
- ReplayGain (track, album, off) per player node, with peak protection.
- 10-band equalizer with presets, spectrum analyzer, sleep timer, resume points.
- `requiresLocalFiles`: offline, tracks with no local file are passed over without a request.
- 89 tests, including a real `AVAudioEngine` playing fixture audio.
