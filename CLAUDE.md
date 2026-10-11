# CLAUDE.md — music-ios

**own.audio Music**: one open-source (MPL-2.0) native iOS music player for own.audio,
Subsonic/OpenSubsonic and Jellyfin servers, published by own.audio. The repository is public —
write everything for strangers to read.

- Work phase by phase from `IMPLEMENTATION_PLAN.md`; tick phases there.
- Every change gets a `CHANGELOG.md` entry under `[Unreleased]`.
- **No own.audio internals**: no references to closed repositories, internal hosts, team IDs or
  credentials. Comments explain why, for an outside reader.
- own.audio is one server among the others, never a funnel.
- **Keep it small** (the plan's principles): no third-party dependencies without a strong
  reason; server clients by hand; system decoders only — no VLC/FFmpeg, the server transcodes
  what iOS can't play; no cross-platform frameworks. Check the app's size on every release.
- A feature a server lacks is hidden, not broken: the screens ask the source what it can do.

## Build

```bash
xcodegen generate                       # after changing project.yml; the .xcodeproj is not committed
(cd Packages/SubsonicKit && swift test)
(cd Packages/OwnAudioKit && swift test)   # live tests too with OWNAUDIO_HOST/EMAIL/ACCOUNT_PASSWORD set
(cd Packages/JellyfinKit && swift test)
(cd Packages/PlayerEngine && swift test)   # includes a real AVAudioEngine playing fixtures
xcodebuild -project OwnAudioMusic.xcodeproj -scheme OwnAudioMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Editor shows "no such module" on code that builds? Run
`xcode-build-server config -project OwnAudioMusic.xcodeproj -scheme OwnAudioMusic`
(`buildServer.json` is gitignored).

## Tests against real servers

Credentials live in the gitignored `test-servers.local.env` (the variables are listed at the
top of `scripts/test-servers.sh`); never commit them. `scripts/test-servers.sh` runs the live
client tests and the UI tests against each server; `ONLY_TESTING=<test>` runs one UI test.
UI tests need `-test-timeouts-enabled YES -default-test-execution-time-allowance …`, or a stuck
query hangs for ever.

- own.audio's Subsonic login is the account email plus a per-user Subsonic key, not the
  account password; the script fetches the key.
- A throwaway Navidrome: `docker run -d -p 4533:4533 -v <music>:/music:ro -v <data>:/data
  deluan/navidrome`, then `POST /auth/createAdmin`, then `/rest/startScan.view`. Tagged test
  tones made with ffmpeg are enough.

## Release

TestFlight: `scripts/testflight.sh` (needs `DEVELOPMENT_TEAM` in the gitignored
`release.local.env` and the account signed in to Xcode). The Team ID stays out of `project.yml`
because the repo is public. App icons must have no alpha channel.

## Layout

- `App/OwnAudioMusic/` — the app.
- `Packages/SubsonicKit/` — Subsonic/OpenSubsonic client, Foundation only.
- `Packages/OwnAudioKit/` — own.audio's own API (`/api/v2`), Foundation only.
- `Packages/JellyfinKit/` — Jellyfin client, Foundation only.
- `Packages/PlayerEngine/` — `MusicEngine` + `PlayerCore`; knows tracks by an opaque id,
  nothing about servers.
- `docs/history/` — plans and changelogs of the three repositories merged here.
