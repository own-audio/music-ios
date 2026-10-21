# CarPlay — how competitor apps look, and what ours should show

Research of 2026-10-21. Pocket Casts, BookPlayer and Amperfy are open source, so their CarPlay
code was read directly (current `trunk`/`develop`/`master`). The others are closed: what is
known comes from press and forums, often years old, and is marked *uncertain* where it is.

## What our apps show today

| App | Start screen | Now Playing |
|---|---|---|
| Music | one list: Recently Played, Recently Added, Downloads, Playlists, Artists, Favorites | system default (no extra buttons) |
| Books | one list: Continue Listening, Downloads, Library, Series, Authors | speed button; Up Next opens Chapters |
| Podcasts | one list: New Episodes, Downloads, Shows | speed button; Up Next opens Chapters |

Unit tests for these lists: `UnitTests/CarPlayContentTests` in each app (2026-10-21).

## Apple's rules that matter

- Audio apps: `CPTabBarTemplate` (root only; tab roots are lists or grids), `CPListTemplate`,
  `CPGridTemplate`, `CPNowPlayingTemplate`.
- Tabs: read `CPTabBarTemplate.maximumTabCount`; guides report **4 for audio apps**.
- Lists: `maximumItemCount` / `maximumSectionCount` are set per car at runtime (Pocket Casts:
  100 items); at most 5 levels deep. `CPListImageRowItem` gives a row of artwork tiles.
- Siri "assistant cell" at the top of a list needs `INPlayMediaIntent`.
- Now Playing buttons: playback rate, repeat, shuffle, add to library, more, and image buttons of
  your own; plus the system's Up Next (custom title) and Album/Artist buttons.
- Screen sizes (HIG): 800×480, 960×540, 1280×720, 1920×720, landscape and portrait, @2x/@3x;
  the CarPlay Simulator also has 768×1024 portrait and a 748×456 minimum.
- Don't start playing on your own except to resume; show Now Playing as soon as audio is ready;
  never require the phone; report errors on the car's screen.

## Podcasts

| App | Tabs | Now Playing | Notes |
|---|---|---|---|
| Pocket Casts (code) | Podcasts, Playlists, Downloads, More (History, Files) | mark played, speed list (0.5–3), Chapters (when the episode has them), star; Up Next and Album/Artist on | reorderable tabs; 100-item cap; can't add to Up Next from the car |
| Apple Podcasts | Listen Now (Up Next, Recently Played), Browse, Library | speed, Up Next (*uncertain*) | full Siri |
| Overcast | Recents, playlists, podcasts (*uncertain*) | speed and chapters (2021) | next/previous skip 30 s |
| Castro | Queue, Inbox (2016) | — | the two-tab "new / my picks" model works well in a car |

## Audiobooks

| App | Tabs | Now Playing | Notes |
|---|---|---|---|
| BookPlayer (code) | Recent (last 20), Library (folders) | previous chapter, Controls list (boost, speed 0.5–4), add bookmark (with alert), Chapters or Bookmarks list, next chapter | chapter rows show start and length |
| Audible | library (2015); current tabs unknown | skip = 30 s or chapter, per setting | — |
| Prologue (Plex/ABS) | CarPlay listed; layout unknown | — | chapters, sleep at end of chapter |
| plappa | "CarPlay (WIP)", no code | — | — |

## Music

| App | Tabs | Now Playing | Notes |
|---|---|---|---|
| Amperfy (Subsonic, code) | Home (artwork rows), Library, Cached (offline only), Playlists | repeat, shuffle, favourite, speed; Up Next and Album/Artist on | Siri cell; "Disconnected" screen when the server is away |
| Spotify | Home, Recently Played, Browse, Library (2021; *uncertain* now) | shuffle, repeat, add to library, queue | — |
| Apple Music | Listen Now, Radio, Library (*uncertain*); iOS 26: 6 pins in Library | shuffle, repeat, Up Next | deep Siri |
| Plexamp | Home, Library, Downloads (*uncertain*) | — | users complain the library is empty offline |

## What ours should show (proposal)

All three: tabs instead of one list (at most 4, cut to `maximumTabCount`); a Siri cell; skip
intervals from the settings; Up Next and Album/Artist on; a clear offline/disconnected screen
instead of an empty list.

- **Music:** Home (artwork rows: Recently Played, Recently Added, favourite playlists, a mix),
  Library (Artists, Albums, Playlists, Genres, Favorites), Downloads (offline only, same shape),
  Playlists. Now Playing: shuffle, repeat, favourite; Up Next = the queue; Album/Artist opens the
  album.
- **Books:** Continue, Library (authors, series, covers), Downloads. Now Playing: previous and
  next chapter, speed, add bookmark, Chapters via Up Next; a sleep timer (end of chapter) in a
  More list would beat everyone surveyed.
- **Podcasts:** Up Next, New Episodes, Shows, Downloads. Now Playing: speed, Chapters (when
  there are any), mark played; Album/Artist opens the show; Play Next / Add to Up Next from the
  car's lists, which Pocket Casts can't do.
