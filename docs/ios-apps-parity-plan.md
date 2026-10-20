# iOS apps — parity plan

This plan brings every feature that makes sense in all three apps (Music, Books,
Podcasts) into all three. It is built from the gaps in
[ios-apps-feature-parity.md](ios-apps-feature-parity.md) (2026-10-18). When a
phase is done, tick it here and update that table.

The approach: where one app already does something well, it is the model, and
the others copy its behaviour and wording. **The apps stay standalone** (decided
2026-10-18): no shared package. Code is copied from the model app, keeps its file
names, and the changelog says where it came from. Each app's own `IMPLEMENTATION_PLAN.md`
still decides the details. This plan only says *what* has to match.

## Deliberately different (not part of parity)

These stay in one app because they only make sense for its content.

- **Music only:** gapless, crossfade, ReplayGain, EQ, lyrics, format badge, shuffle/repeat, ratings, smart playlists, Instant Mix, MusicBrainz identify, playlist editing.
- **Books only:** bookmarks, series/authors/narrators, import from the phone, ebook narration, reset progress.
- **Podcasts only:** no-server mode, gPodder, feed follow/unfollow, inbox, OPML, transcripts, summaries and Ask.
- **Spoken apps only (Books, Podcasts):** speed, skip intervals, smart rewind, "Continue from another device?", chapters, the end-of-chapter sleep timer.
- **Server support** stays as each app's plan has it: Music speaks Subsonic and Jellyfin, Books and Podcasts speak Audiobookshelf, Podcasts speaks gPodder.

## P1 — Small consistency fixes

Each item takes about an hour; do this phase first.

- [x] Music: give it its own accent colour (the AccentColor asset is empty)
- [x] Music: Privacy link in Settings → About (as in Books/Podcasts)
- [x] Music: show Apple/Google buttons only when the server offers them (Books/Podcasts: `ProviderButtons`, 600 ms after typing)
- [x] Podcasts: canary button in TestFlight/Debug builds (`TestServers.swift` from Books)
- [x] Books + Podcasts: one set of speed presets (0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3) — *Podcasts done 2026-10-19*
- [x] Books: Live Activity button icons follow the chosen skip intervals
- [x] Podcasts: hide Unfollow on own.audio and Audiobookshelf shows until it works
- [x] Podcasts: README lists only what ships; the rest goes under "Coming"

## P2 — Player parity

- [x] Music: "End of track" button in the sleep sheet (the engine has `startUntilEndOfItem`)
- [x] Music: sleep countdown badge on the cover
- [x] Music: resume position — either read it back (e.g. for long tracks and mixes) or delete the store — *read back: the last queue keeps the position across a relaunch, 2026-10-20*
- [x] Books + Podcasts: AirPlay button in the player (`AirPlayRouteButton` from Music) — *Podcasts done 2026-10-19*
- [x] All three: restore the last item in the mini player after a relaunch, paused at its position — *Podcasts and Books 2026-10-19, Music 2026-10-20*
- [x] Podcasts: chapters read from the audio file when the feed has none (as Books does)

## P3 — Downloads and offline parity (Podcasts P7)

This is the biggest phase. Books is the model.

- [x] Podcasts: download an episode — background `URLSession`, Application Support, excluded from backup
- [x] Podcasts: Downloads tab — rows named by server, swipe to remove, Remove All, Retry N Failed
- [x] Podcasts: per-show auto-download, delete when played, keep N
- [x] Podcasts: Download on Wi-Fi Only and Keep at Most (storage limit with eviction)
- [x] Podcasts: On Mobile Data — Original / Saver / Downloaded Only, and Low Data Mode — Stream / Downloaded Only (a feed has no Saver)
- [x] Podcasts: wire the listening cache (`TrackFileCache`)
- [x] Podcasts: Offline Mode switch in Settings as well
- [x] Podcasts: offline progress queue that retries (`PendingProgress` from Books)
- [x] Music: Download on Wi-Fi Only and Keep at Most (storage limit with eviction)
- [x] Music: downloads in a background session that survives a kill (now they resume on the next launch)

## P4 — Accounts and server parity

- [x] Music + Podcasts: Devices screen — signed-in devices, sign one out, Sign Out Everywhere (`DevicesView` from Books) — *Podcasts 2026-10-19, Music 2026-10-20*
- [x] Podcasts: Family screen (`HouseholdView` from Books/Music)
- [x] Podcasts: live `/events` updates from own.audio while in the foreground
- [x] Books: server logos in the list, menu and detail page
- [x] Books: screen to add your own addresses and pin a fixed connection (the model supports it)

## P5 — System integration

Books is the model for all of these.

- [x] Music + Podcasts: Continue Listening / Recently Played widget (App Group snapshot) — *Podcasts 2026-10-19, Music 2026-10-20*
- [x] Music + Podcasts: Live Activity (lock screen and Dynamic Island, with buttons that work without opening the app) — *Podcasts 2026-10-19, Music 2026-10-20*
- [x] Music + Podcasts: Siri / App Intents ("Play … in own.music", "Continue my podcast"), phrases in English and Czech — *Podcasts 2026-10-19, Music 2026-10-20*
- [x] Music + Podcasts: deep links (`ownmusic://`, `ownpodcast://`, plus `podcast://` and `feed://` for following a show) — *Podcasts 2026-10-19, Music 2026-10-20*
- [x] Podcasts: CarPlay (lists: New Episodes, Downloads, Shows)
- [ ] All three: try CarPlay, the widget and the Live Activity on a real device and in a car

## P6 — Browsing parity

- [x] Podcasts: Up Next queue UI — Play Next, Play Later, reorder; the logic and tests are already in `FeedLibrary`
- [x] Music: Play Next / Add to Queue, plus reorder and remove in the queue sheet
- [x] Podcasts: search your own shows and episodes, beside the directory search
- [x] Podcasts: iPad sidebar (split view)
- [x] Books: Favourites list or filter (the badge is never set yet)
- [x] Podcasts: sort shows (title, recently updated) and filter episodes (unplayed, downloaded)

## P7 — Shared quality

- [x] All three: log viewer with export in Settings, for bug reports (no analytics) — *Podcasts and Books 2026-10-19, Music 2026-10-20*
- [x] All three: background refresh (`BGAppRefreshTask`) — feeds for Podcasts, the catalogue for Music/Books — *Podcasts and Books 2026-10-19, Music 2026-10-20*
- [ ] All three: UI tests for every feature added in P1–P6, in English and Czech and at the largest text size — *each app has its features' tests in English, a Czech and a largest-text pass; not every new feature in Czech yet*
- [x] Update the parity table and the statistics — *2026-10-20*

## Open questions

- Should Music resume inside long tracks (P2), or is the store dead code?
- Bookmarks for Podcasts: some podcast apps have them. Should ours?
