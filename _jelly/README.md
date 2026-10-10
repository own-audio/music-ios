# own.audio for Jellyfin

A native iPhone and iPad music player for [Jellyfin](https://jellyfin.org). Swift and SwiftUI,
no web views. In development; the plan is in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

The player is [player-engine](https://github.com/own-audio/player-engine), shared with
[own.audio for Subsonic](https://github.com/own-audio/subsonic-ios).

Made by [own.audio](https://www.own.audio). Free, no account, no tracking.

## Build

```bash
cd Packages/JellyfinKit && swift test
```

Live tests against a real server: put `JELLYFIN_HOST`, `JELLYFIN_USER` and `JELLYFIN_PASSWORD`
in the environment (or in the gitignored `test-servers.local.env`) and run
`swift test --filter Live`. They put back what they change.

## License

[Mozilla Public License 2.0](LICENSE).
