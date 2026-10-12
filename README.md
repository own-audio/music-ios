# own.audio Music

A native iPhone and iPad music player for your own server: **own.audio, Subsonic and
OpenSubsonic servers (Navidrome, Gonic, Airsonic, LMS, Ampache…) and Jellyfin**, side by side
in one app. Swift and SwiftUI, no web views, no third-party dependencies — a few megabytes.

In development: today the app speaks Subsonic; Jellyfin and own.audio are being brought in from
the two apps this one replaces (own.audio for Subsonic and own.audio for Jellyfin). The plan is
in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

- Gapless playback and crossfade, on AVAudioEngine
- Streams while it downloads, with its own Core Audio decoder
- Downloads and an offline mode: with no network it shows and plays what is on the phone
- Synced lyrics, volume leveling, equalizer
- Favorites, ratings, playlists, play reporting
- Several servers at once, iPad; CarPlay is built but not yet tried in a car
- English and Czech

Made by [own.audio](https://www.own.audio). Free, no account needed, no tracking.

## Build

Developed with Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen); runs on iOS 18
and later.

```bash
brew install xcodegen
xcodegen generate
open OwnAudioMusic.xcodeproj
```

The packages test on their own (`swift test` in each). Tests against real servers and the UI
tests are described in [CLAUDE.md](CLAUDE.md).

## Layout

- `App/` — the app
- `Packages/SubsonicKit` — Subsonic/OpenSubsonic client
- `Packages/OwnAudioKit` — own.audio's own API (`/api/v2`)
- `Packages/JellyfinKit` — Jellyfin client
- `Packages/PlayerEngine` — the player (`MusicEngine`, `PlayerCore`); knows nothing about servers
- `UITests/` — end-to-end tests against real servers
- `docs/history/` — plans and changelogs of the projects merged into this one

## License

[MPL-2.0](LICENSE). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

The Jellyfin logo (`App/OwnAudioMusic/Assets.xcassets/JellyfinLogo.imageset`) marks Jellyfin
servers in the server list. It is © the Jellyfin contributors, from
[jellyfin-ux](https://github.com/jellyfin/jellyfin-ux), under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), used as the project's
[branding guide](https://jellyfin.org/docs/general/contributing/branding/) allows: to show
that the app works with Jellyfin, not as this app's logo.
