# Battery, offline listening and the lock screen — plan for the three iOS apps

Written 2026-10-24 for music-ios, book-ios and podcast-ios. All three apps share
copied code (iOS apps standalone), so most work items repeat in each repo. Line
numbers are from the code read on that date.

Three asks:

1. Check the apps for battery use and fix what drains it.
2. Books (and podcasts): a downloaded file is always played from disk, also
   when online; when streaming, keep 5–15 minutes ahead **on disk** so playback
   survives a metro tunnel or a car with no signal.
3. Lock screen: remove our own mini player (the Live Activity), keep the
   system Now Playing controls.

Order: L (lock screen) first, because it is small and removes code that the
battery items would otherwise have to fix. Then B (battery), then O (offline).

---

## L — Remove the Live Activity (all three apps)

Today each app shows **two** players on the lock screen: iOS's Now Playing
controls (from `NowPlayingController`, `MPNowPlayingInfoCenter`) and our Live
Activity below it. The Live Activity is the only extra one. There are no
lock-screen accessory widgets and no Control Center controls. Now Playing does
not depend on the Live Activity, so it stays as it is, including in the Dynamic
Island and on CarPlay.

Per repo (music / book / podcast):

| Remove | music-ios | book-ios | podcast-ios |
|---|---|---|---|
| Live Activity UI | `Widgets/TrackLiveActivity.swift` | `Widgets/BookLiveActivity.swift` | `Widgets/EpisodeLiveActivity.swift` |
| Line in the widget bundle | `Widgets/RecentlyPlayedWidget.swift:8` | `Widgets/ContinueListeningWidget.swift:8` | `Widgets/UpNextWidget.swift:8` |
| Attributes + `PlaybackControlIntent` | `Shared/TrackActivity.swift` | `Shared/BookActivity.swift` | `Shared/EpisodeActivity.swift` |
| Controller | `Core/LiveActivityController.swift` | same | same |
| Uses in `AppModel` | L318–321 | L72, L107, `tick()` L1015 | L117, L189, `tick()` L667 |
| `NSSupportsLiveActivities` | `project.yml:31` (+ comments L32, L75) | `project.yml:29` | `project.yml:40` (+ L47, L86) |

- **App Group:** keep the App Group and the `appGroup` constant if the
  home-screen widget's snapshot uses it. Move it out of `*Activity.swift` first.
  The cover JPEG the controller wrote into the group goes.
- **Unchanged:** the home-screen widgets (Recently Played / Continue Listening /
  Up Next), the deep links (`ownmusic://player`, `ownbook://play/`,
  `ownpodcast://play/`) and the Siri intents.
- **Docs:** update CHANGELOG (a Removed entry), the README/IMPLEMENTATION_PLAN
  lines that describe the Live Activity, and `docs/ios-apps-feature-parity.md`.
- **Users:** a running activity from the old build ends when iOS sees the
  extension no longer has it. Nothing to migrate.
- **Test:** build, play, lock the phone: one player only, and its controls
  work. Also check CarPlay and the Dynamic Island.

This also removes these battery items: the Live Activity pushed every 15–20 s
while playing, and its cover fetch retried on every sync.

---

## B — Battery

From a code read, not measured on a device. Measure before and after with
Instruments' Energy Log on a real phone: play for 30 min locked, then pause
and leave it for 30 min.

### B1 — music: stop the audio engine when not playing (HIGH)
`PlaybackEngine.swift`: `pauseAudioOnly()` (530) and `stop()` (555–596) stop
only the player nodes. `AVAudioEngine` keeps rendering silence, so with the
audio background mode iOS never suspends the app, even after Stop.

- Pause: pause the engine after a grace period of about 30 s. A quick
  resume stays instant.
- Stop and interruptions: stop the engine.
- Route changes while paused: don't restart the engine
  (`handleEngineConfigurationChange`, 375).
- Stop: `AVAudioSession.setActive(false, options: .notifyOthersOnDeactivation)`.
- **Test:** pause → background → after the grace period the app is
  suspended (Xcode's debug gauge shows 0 % CPU), and play from the lock screen
  still works.

### B2 — music: report progress only while playing (HIGH on Jellyfin)
`AppModel.swift:975–987`: the 15 s loop never ends and sends
`reportSession(.progress)` while paused. Cancel it on pause and stop, restart it
on play. Send one report on pause.

### B3 — podcast: no full refresh on every return or network change (HIGH)
- `RootView.swift:25` counts `.inactive` (Control Center, notification
  shade, Face ID) as background. Count only `.background`.
- `refresh()` (`AppModel.swift:1498`) and the network handler (190–196)
  run gPodder sync, every RSS feed, a request per show and download rules. Give
  them a minimum interval of 15 min, skip them in the background while playing,
  and don't pass `force: true` to Audiobookshelf's RSS (it skips its own 600 s
  cache).

### B4 — book + podcast: fewer progress reports and file writes (HIGH)
- **book:** every 10 s of playback (`SpokenEngine.tickIntervalSecs`) causes
  a server request plus about 5 file writes. These include the UserDefaults
  blob of every book, `known-positions.json`, `pending-progress.json` and
  `LastBook`.
- **podcast:** every 10 s, about 3 writes and a request. `FeedLibrary`
  rewrites the whole `state.json`.
- **Fix:**
  - keep the local position every 10 s, written as one file;
  - send to the server every 60 s, and at once on pause, seek, chapter
    change, stop and going to the background;
  - this keeps the cellular radio asleep between reports.
- Audiobookshelf's play session needs a sync now and then. 60 s is within
  what its own apps do.

### B5 — book: the widget reloads every minute (HIGH)
`Shared/WidgetSnapshot.swift:38`: `Self.load() != self` compares the
snapshot's `at` date too, so it never matches. Compare `entries` only, as music
and podcast do, and don't refresh the widget from position ticks. Refresh it
on play, pause and book change only.

### B6 — all: debounce network changes (MEDIUM)
`NetworkMonitor.onChange` triggers `chooseAddresses()` (a race of every server
address) plus flushes and re-syncs on every path change, including cell
handovers in a car.
- Debounce 3 s, and ignore changes that only reorder interfaces.
- In the background, only flush progress.

### B7 — the smaller items (MEDIUM/LOW)
- **music:**
  - the 4 Hz tick (`PlaybackEngine.swift:1493`) at 1 Hz in the background;
  - `MarqueeText` (`PlayerSupport.swift:110`, `TimelineView(.animation)`)
    stops after one scroll cycle;
  - the stream reader copies one byte at a time (`StreamingTrackSource.swift:87`)
    → read in chunks;
  - the concert position loop stops on pause;
  - Identify screens poll and listen to SSE at once → SSE only, throttled
    reload.
- **book:**
  - narration polling every 4 s → back off to 60 s, stop when the server is
    gone;
  - the progress fetch every 3 min → only in the foreground;
  - the shelves reload on every pause → only when the app is visible.
- **podcast:**
  - artwork for Now Playing and the widget goes through the disk-cached,
    downscaled `ArtworkLoader` (`AppModel.swift:685`, `Platform.swift:10`);
  - rule-driven downloads are `isDiscretionary`.
- **all:**
  - `isInForeground` starts `false` until a scene is active, so CarPlay and
    background launches don't open event streams;
  - progress callbacks from downloads are throttled before they reach the
    main thread.

---

## O — Offline listening for books (and podcasts)

### What happens today (book-ios)
- **Downloads:** used only when the **whole** book is downloaded, and checked
  once at play (`AppModel.swift:821`). A partly downloaded book streams every
  file, including the ones on disk. A download that finishes mid-playback is
  never used until the book is played again. Seeks into another file never ask
  for a local copy.
- **Streaming:** AVPlayer holds about 3 minutes **in memory**
  (`preferredForwardBufferDuration` 180). The listening cache downloads whole
  files, **on Wi-Fi only**, so on cellular nothing is on disk.
- **Signal loss:** after the 3 minutes run out the item fails, the one link
  refresh fails offline, and playback stops for good. Nothing resumes when the
  signal comes back.
- **podcast-ios:** has the same engine; a cached episode still streams
  because `play()` never checks the listening cache.

### O1 — Local file first, per file, every time
- One `locate(part)` for both play and the engine's `partLocator`. In this
  order:
  1. the downloaded file (`DownloadManager.fileURL(compositeId:fileId:)`,
     already per file);
  2. the listening cache;
  3. the stream.
- `play()` asks it per part, so a partly downloaded book uses what it has.
- `seek` into another part asks it too (today `loadPart` uses the timeline's
  URL).
- **A download finishing mid-playback:** `DownloadManager` posts it, and the
  engine swaps that part's URL in the timeline. The part playing now is
  switched at the next pause or seek, not mid-sentence.
- The listening-cache prefetch chain keeps going when a part had no local
  copy (today it stops).
- **podcast:** `play()` asks the listening cache.
- **Tests:** unit tests for the locator order, a partly downloaded book, a
  download completing mid-book, and a seek into a downloaded part.

### O2 — A look-ahead window on disk, on any network
The main piece. While streaming, keep **N minutes ahead of the playhead on
disk**: a setting of 5 / 10 / 15 min, default 10. That is about 5–15 MB at
64–128 kbps, cheap on cellular, unlike the whole-file listening cache.

**How:**
- Play streamed parts through an `AVAssetResourceLoaderDelegate` (a custom URL
  scheme mapped back to the real link). The loader serves AVPlayer's range
  requests from a per-part sparse cache file and fetches what is missing with
  HTTP Range.
- Both servers answer Range with 206; the live tests already assert it.
- **Prefetcher:** keeps the bytes for `playhead … playhead + N min` on disk.
  - Bytes per second are estimated from the part's size and duration. The
    estimate is rough for VBR, so add 20 % margin.
  - Near the end of a part it fetches the start of the next part.
  - Chunks of 256 KB–1 MB, fetched in a burst, then the radio is idle. Good
    for battery too.
- **Range map:** which byte ranges of a part are on disk. Kept next to the
  cache file so a relaunch or a later replay uses it.
- **Eviction:** the window shares the 1 GB listening-cache cap (LRU by
  book). The part being played is protected.
- **Links:**
  - own.audio's links last 6 h; its original-file link redirects to storage,
    presigned for 1 h. Refresh through `partURL` when a fetch gets 401/403 or
    the link is about to expire.
  - Audiobookshelf's `?token=` lasts as long as the token.
- **What is not covered at first:**
  - **Data saver on:** own.audio sends a transcode stream not seekable by
    Range, and Audiobookshelf sends HLS. Option for later: fetch the
    transcode stream sequentially into the window.
  - **Audiobookshelf HLS** in general.
- **Cellular use:** the window is small and runs on cellular. Low Data Mode
  (`isConstrained`) still gets it, but at 5 min.

### O3 — Riding out the gap, and coming back
- **When the window runs out offline:** pause with "No signal — waiting",
  not an error.
- **When the network returns** (`NetworkMonitor`): refresh the link if
  needed and resume from the position, if the pause came from signal loss
  and not from the user.
- `recover()` retries with backoff (2 s doubling to 30 s) while offline,
  instead of one attempt.
- **UI:** the player shows how much is saved ahead ("8 min saved"), so the
  user knows before entering the metro.
- **Test:**
  1. Network Link Conditioner / airplane mode during playback of a
     multi-file book on own.audio and on Audiobookshelf (NAS 2.37.1);
  2. play 10 min offline;
  3. turn the network back on;
  4. it resumes by itself;
  5. progress reaches the server.

### O4 — Podcasts get the same
Same `SpokenEngine`, so O2–O3 come over almost as they are, for single-part
episodes. Music has its own engine. It already writes the whole track to disk
while streaming and plays downloads first, so it needs nothing here.

---

## Questions for Kornel

1. **Window size:** a setting of 5 / 10 / 15 min with 10 as default. Or a
   fixed 15 min?
2. **The window and mobile data:** use mobile data even when the Wi-Fi-only
   download setting is on? It is a few MB, and that is what makes the metro
   case work. My suggestion: yes.
3. **Order:** L in all three apps first (small, one TestFlight round), then
   B1–B5, then O1–O3 in book-ios, then O4 in podcast-ios?
