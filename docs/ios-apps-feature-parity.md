# iOS apps — feature parity

Music (`music-ios`, own.music), Books (`book-ios`, own.book) and Podcasts
(`podcast-ios`, own.podcast) side by side, so nothing is forgotten and the three
stay consistent. Taken from the code on 2026-10-18, the Podcasts and Books columns updated 2026-10-19 and Music 2026-10-20 after their parity work; where a README claims more
than the code does, the table follows the code.

Update a row when a feature lands, and tick the list at the bottom.

**Legend:** ✅ works · ◐ partly there (code exists but isn't fully wired, or isn't tested) · 📋 planned only · — missing · n/a doesn't apply to this app

The plan that closes the gaps is [ios-apps-parity-plan.md](ios-apps-parity-plan.md).

## Statistics (2026-10-20, after the parity work in all three)

The counts come from the rows of the tables below. Rows that only describe something (such as "Tabs" or "Engine") and n/a rows are left out. "Done" is the share of the rows that apply to that app.

| | Music | Books | Podcasts |
|---|---|---|---|
| ✅ works | 66 | **68** | 62 |
| ◐ partly there | 2 | 3 | 3 |
| 📋 planned | 0 | 0 | 2 |
| — missing | **9** | **9** | 13 |
| Rows that apply | 77 | 80 | 80 |
| **Done** | **86 %** | 85 % | 78 % |
| Swift lines, app (+ widgets) | **12.1k** | 8.7k | 7.9k |
| Swift lines, packages | **11.0k** | 7.0k | 8.0k |
| Unit tests (about) | **~290** | ~130 | ~175 |
| UI tests | 32 | 30 | **37** |

- **All three now share the same frame** (2026-10-20): the last item back after a relaunch, a sleep badge on the cover, Devices, Wi-Fi only and Keep at Most, a widget, a Live Activity, Siri, links, a log viewer and background refresh. Music caught up last, from 67 % to 86 %.
- **What is left is mostly what doesn't fit an app's content**: speed and skip intervals in Music, ratings and identify outside Music, import and narration outside Books, summaries and Ask outside Podcasts. Handoff, Spotlight, notifications and a licences screen are missing in all three.
- **Music is the biggest** and has features none of the others has (MusicBrainz identify, smart playlists, EQ, ReplayGain, crossfade, lyrics); several of those count as one row each.
- **Podcasts** still has OPML, Jellyfin and a transcript viewer left in its own plan.

## Servers & sign-in

| Feature | Music | Books | Podcasts |
|---|---|---|---|
| own.audio | ✅ | ✅ | ✅ (can't follow or unfollow shows) |
| Audiobookshelf | — | ✅ (book libraries) | ✅ (podcast libraries) |
| Subsonic / Navidrome | ✅ | — | n/a |
| Jellyfin | ✅ (+ Quick Connect) | — | 📋 |
| gPodder sync | n/a | n/a | ✅ |
| No server needed | — | — | ✅ |
| Server type detected automatically | ✅ | ✅ | ✅ |
| Password, two-factor (own.audio) | ✅ | ✅ | ✅ |
| Sign in with Apple / Google | ✅ | ✅ | ✅ |
| Apple/Google buttons shown only when the server offers them | ✅ | ✅ | ✅ |
| "Try the demo" button | ✅ | ✅ | ✅ |
| Canary button (TestFlight builds) | ✅ | ✅ | ✅ |
| Several servers + switch menu | ✅ Home | ✅ Home (+ each ABS library) | ✅ New Episodes (+ "All Sources" merged) |
| Server page: status, Check Now, Sign In Again | ✅ | ✅ | ✅ |
| Add your own addresses / fixed connection in the UI | ✅ | ✅ | ✅ |
| Address racing, own.audio address rewrite | ✅ | ✅ | ✅ |
| Server logos | ✅ | ✅ | ✅ |
| "Library on This iPhone" with Update Now | ✅ | ✅ | n/a |
| Devices list / Sign Out Everywhere | ✅ | ✅ | ✅ on the server page |
| Family screen (members, invites, credit) | ✅ | ✅ | ✅ on the server page |
| App key sign-in | — | — | — |

## Browsing

| Feature | Music | Books | Podcasts |
|---|---|---|---|
| Tabs | Home, Library, Playlists, Downloads, Search | Home, Library, Downloads, Search | New Episodes, Shows, Downloads, Search |
| Home shelves | ✅ | ✅ | — (the inbox instead) |
| Sort / filter | ✅ albums / artists | ✅ 4 sorts + progress filter | ✅ shows: 3 sorts; episodes: all / unplayed / downloaded |
| Search your own library | ✅ | ✅ | ✅ shows and episodes, offline too |
| Grid/list switch | — | ✅ | — |
| iPad sidebar | ✅ | ✅ | ✅ |
| Favourites list | ✅ | ✅ filter in Library, badge on covers | — |
| Pull to refresh, "That Didn't Work" alert | ✅ | ✅ | ✅ |

## Playback

| Feature | Music | Books | Podcasts |
|---|---|---|---|
| Engine | MusicEngine (AVAudioEngine) | SpokenEngine (AVPlayer) | SpokenEngine |
| Full player + mini player | ✅ | ✅ | ✅ |
| Speed | — | ✅ per book + default | ✅ per show + default |
| Speed presets | n/a | 0.75 / 1.25 | 0.75 / 1.25 |
| Skip intervals (also on the lock screen) | — | ✅ | ✅ |
| Smart rewind | n/a | ✅ | ✅ |
| Sleep timer in minutes, +10 min | ✅ | ✅ | ✅ |
| Sleep timer to end of track / chapter / book | ✅ end of track | ✅ | ✅ |
| Sleep countdown on the cover | ✅ | ✅ | ✅ |
| Resume position | ✅ with the last queue | ✅ | ✅ |
| "Continue from another device?" dialog | n/a | ✅ | ✅ |
| Chapters | n/a | ✅ (server, file, per file) | ✅ (feed, server, file) |
| Bookmarks | n/a | ✅ | — |
| Queue | ✅ Play Next, Add to Queue, reorder, remove | — | ✅ Up Next across sources: reorder, remove, plays on |
| Last item back after relaunch | ✅ the whole queue, paused | ✅ shown, loaded on play | ✅ |
| AirPlay button | ✅ | ✅ | ✅ |
| Lock screen, interruptions, headphones unplugged | ✅ | ✅ | ✅ |
| Mobile data: Original / Saver / Downloaded Only | ✅ | ✅ | ✅ Stream / Downloaded Only (a feed has no Saver) |
| Listening cache | ✅ | ✅ | ✅ |
| CarPlay | ✅ never tried in a car | ✅ not tried on a device | ✅ simulator only until Apple grants the entitlement |
| Gapless, crossfade, ReplayGain, EQ, lyrics, format badge | ✅ | n/a | n/a |

## Downloads & offline

| Feature | Music | Books | Podcasts |
|---|---|---|---|
| Download single items | ✅ | ✅ | ✅ |
| Download a whole set | ✅ album / playlist | ✅ series / author / collection / filtered list | ✅ per-show rules (newest N, delete when played, keep at most) |
| Downloads tab, named by server, Remove All | ✅ | ✅ | ✅ |
| Downloads survive the app being killed | ✅ background session | ✅ background session | ✅ background session |
| Wi-Fi only, storage limit with eviction | ✅ | ✅ | ✅ |
| Offline switch on Home beside Settings | ✅ | ✅ | ✅ |
| Offline switch in Settings | ✅ | ✅ | ✅ |
| Offline banner above the mini player | ✅ | ✅ | ✅ (in the inbox) |
| Automatically offline with no network | ✅ | ✅ | ✅ |
| Whole Library When Offline | ✅ | ✅ | n/a |
| Changes made offline sent later | ✅ | ✅ | ✅ |

## Sync

| Feature | Music | Books | Podcasts |
|---|---|---|---|
| Progress / plays reported | ✅ (can be turned off) | ✅ | ✅ |
| Live `/events` updates from own.audio | ✅ | ✅ | ✅ |
| Mark played or finished | n/a | ✅ | ✅ |
| Reset progress | n/a | ✅ | — |
| Favourites | ✅ | ✅ own.audio | — |
| Ratings | ✅ | — | — |
| Edit playlists or collections | ✅ | — (browse only) | n/a |

## Extras

| Feature | Music | Books | Podcasts |
|---|---|---|---|
| Share with the family per item | ✅ | ✅ | — |
| Import from the phone | — | ✅ | — |
| Your own covers | ✅ | ◐ on import | — |
| MusicBrainz identify | ✅ | — | — |
| Ebook narration (with translation) | — | ✅ | — |
| Summaries and Ask | — | — | ✅ |
| Discover: categories, search, shows like yours | n/a | n/a | ✅ own.audio catalogue, else Apple's charts |
| Smart playlists, Instant Mix | ✅ | n/a | n/a |
| OPML import/export | n/a | n/a | 📋 |
| Transcript viewer | n/a | n/a | ◐ parsed, no viewer |

## System

| Feature | Music | Books | Podcasts |
|---|---|---|---|
| Widget | ✅ Recently Played | ✅ (untested) | ✅ Up Next (untested on a device) |
| Live Activity | ✅ | ✅ (icons follow the skip intervals) | ✅ (icons follow the skip intervals) |
| Siri / App Intents | ✅ | ✅ | ✅ |
| Deep links | ✅ | ✅ `ownbook://` | ✅ `ownpodcast://`, `feed://`, `podcast://` |
| Background refresh, Handoff, Spotlight, notifications | ◐ background refresh only | ◐ background refresh only | ◐ background refresh only |
| Share sheet | invites | invites | Share Feed |

## Settings & look

| Feature | Music | Books | Podcasts |
|---|---|---|---|
| Accent colour | ✅ pink | brown | blue |
| Light/dark follows the system | ✅ | ✅ | ✅ |
| English + Czech | ✅ | ✅ | ✅ |
| About: version, source, licence | ✅ | ✅ | ✅ |
| About: Privacy link | ✅ | ✅ | ✅ |
| Privacy manifest, no analytics | ✅ | ✅ | ✅ |
| Log viewer, licences screen | ◐ log viewer only | ◐ log viewer only | ◐ log viewer only |

## To do

### 1. Podcasts: make the README true

- [x] Downloads (P7) — the biggest gap; the tab is an empty placeholder
- [x] Queue UI (the logic and tests already exist)
- [ ] OPML import/export
- [x] CarPlay
- [x] Widget
- [x] Family library
- [ ] Translation
- [x] Unfollow on own.audio and Audiobookshelf shows: hide it, or make it work (now it ends in an error)
- [x] Until then, trim the README to what ships

### 2. Music

- [x] Define an accent colour (the asset is empty, so it shows system blue, close to the Podcasts blue)
- [x] Read the saved resume position back
- [x] "End of track" sleep timer button (the engine already has it)
- [x] Sleep countdown on the cover
- [x] Show Apple/Google buttons only when the server offers them
- [x] Privacy link in Settings → About

### 3. Bring what only one app has to the others

- [x] Widget, Live Activity, Siri, deep links (Books only) → Music, Podcasts
- [x] Devices screen (Books only) → Music, Podcasts
- [x] AirPlay button (Music only) → Books, Podcasts
- [x] Canary button → Podcasts
- [x] Live `/events` updates → Podcasts
- [x] Mobile-data quality setting → Podcasts
- [x] Offline switch in Settings → Podcasts
- [x] Family screen → Podcasts
- [x] Server logos → Books

### 4. Small differences

- [x] Same speed presets in Books (0.75/1.25) and Podcasts (0.8/1.2)
- [x] Add-your-own-address screen in Books
- [x] Chapters read from the audio file in Podcasts, as Books does
- [x] Bring back the last-played item after a relaunch (none of the three does)
- [x] Books Live Activity: icons follow the chosen skip intervals (now always 15 s back and 30 s forward)
