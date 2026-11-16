---
title: Settings
nav_order: 11
description: "Open Settings with the gear at the top right of Home. Tap Done to close it."
---

# Settings
{: .no_toc }

Open Settings with the gear at the top right of **Home**. Tap **Done** to close it.

1. TOC
{:toc}

## Servers

Your servers, the selected one with a checkmark. Tap one for its page, swipe to **Remove**, or
**Add a Server**. See [Getting started](getting-started.md#several-servers).

## Downloads and offline

| Setting | What it does | Default |
|---|---|---|
| **Downloads** | Shows how much space downloads take; opens the downloads list. | |
| **Offline Mode** | Shows and plays only what is on this iPhone, as the app does on its own with no network. Saves mobile data. | Off |
| **Download on Wi-Fi Only** | Downloads wait for Wi-Fi instead of using mobile data. | On |
| **Keep at Most** | The most space downloads may take: 1, 2, 5, 10, 20 or 50 GB. Over the limit, the songs not played for longest go first, never the one playing. | No Limit |
| **Whole Library When Offline** | Offline screens list everything on the server, from a copy of its catalogue kept on the phone; what isn't downloaded is greyed out. | Off |

More in [Downloads and offline](downloads.md).

## Streaming

| Setting | What it does | Default |
|---|---|---|
| **On Mobile Data** | **Original**, **Saver** (a smaller MP3 from the server as each song plays) or **Downloaded Only**. | Saver |
| **Saver Quality** | 320, 192 or 128 kbps. Shown with Saver chosen. | 192 kbps |

Servers that can't make a smaller stream send the original. With iOS Low Data Mode on, streams
are kept at 128 kbps. Wi-Fi and downloads always get the original file.

## Playback

| Setting | What it does | Default |
|---|---|---|
| **Crossfade** | Songs fade into each other near the end. Off, they play back to back with no gap. | Off |
| **Fade** | How long the crossfade lasts, 1 to 12 seconds. Shown with Crossfade on. | 4 s |
| **Volume Leveling** | **Off**, **Same for Every Song** or **Same for Every Album**, from the ReplayGain values in your files (on Jellyfin, its measured loudness). | Same for Every Song |
| **Equalizer** | Opens the six-band equalizer; shows the preset in use, **Custom** or **Off**. | Off |

Crossfade and the equalizer are also in the player's tools row. See [The player](player.md).

## Accent Colour

The colour of buttons, links and what's playing: **App Colour** (the app's pink, the default),
**Blue**, **Indigo**, **Purple**, **Red**, **Orange**, **Yellow**, **Green**, **Teal**,
**Brown** or **Graphite**. The icon and the widgets keep the app's colour.

## Report Plays to the Server

| Setting | What it does | Default |
|---|---|---|
| **Report Plays to the Server** | Tells the server what's playing and counts plays. | On |

On Subsonic servers a play counts once you've heard half a song or four minutes; Jellyfin
counts by its own rules. Plays made offline are sent later. The server can pass them on to
Last.fm or ListenBrainz, if it is set up to.

## About

- **Version**: the app's version and build number.
- **Source Code and Licence**: the app's code on GitHub.
- **Privacy**: the privacy policy.
- **Logs**: what the app wrote to its log since it started: failed requests, playback trouble,
  syncing. **Share Log** sends it as a text file, for example with a bug report. Nothing is sent
  unless you share it, and no sign-in tokens are in it.
