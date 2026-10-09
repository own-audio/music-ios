# player-engine

The audio engine behind own.audio's open-source players, as a Swift package. iOS 18+,
Swift 6, no dependencies.

- **MusicEngine** — a music player on `AVAudioEngine`: gapless playback, crossfade, its own
  Core Audio decoder so a track plays while it downloads, ReplayGain with peak protection,
  a 10-band equalizer and a spectrum, a queue with shuffle and repeat, an offline mode that
  passes over tracks with no local file.
- **PlayerCore** — what any player needs: Now Playing and the lock-screen controls, a sleep
  timer, resume points, and a file cache that prefers a downloaded copy and otherwise fetches
  from a URL the app supplies.

The engine knows tracks only by an opaque id. The app turns an id into a URL (and, if it keeps
downloads, a local file), so the same engine plays from any server.

Used by [own.audio for Subsonic](https://github.com/own-audio/subsonic-ios) and own.audio for
Jellyfin.

```swift
.package(url: "https://github.com/own-audio/player-engine", from: "0.1.0")
```

```swift
import MusicEngine

let cache = TrackFileCache(remoteURL: { id in try await server.streamURL(for: id) })
let engine = PlaybackEngine(
    fileCache: cache, nowPlayingController: NowPlayingController(),
    settingsStore: PlaybackSettingsStore(), equalizerStore: EqualizerStore(),
    resumeStore: UserDefaultsResumeStore()
)
await engine.play(tracks: [Track(id: "42", title: "Song", artist: nil, album: nil, durationSecs: 180)])
```

`swift test` runs the tests on a Mac, including a real `AVAudioEngine` playing fixture audio.

Licensed under the [Mozilla Public License 2.0](LICENSE).
