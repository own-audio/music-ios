---
title: Privacy
nav_order: 14
---

# Privacy

The app collects nothing. There is no account with us, no analytics, no ads and no tracking.

It talks only to:

- **the servers you add**: your sign-in, requests for your library, the music and covers you
  play, your favorites, ratings and playlists, and, unless you turn off **Report Plays to the
  Server**, what you played;
- **Apple or Google**, only if you choose to sign in with them on an own.audio server.

On the phone, your sign-ins are kept in the Keychain. A Subsonic password is kept there because
the protocol needs it for every request, and only a one-time token made from it is sent;
Jellyfin and own.audio keep only a sign-in token. Your settings, downloads and the copy of your
library stay on the phone and are deleted with the app. Removing a server removes its
downloads and its library copy.

The app asks for access to the local network so it can reach a server at home. When you choose
a cover or picture on own.audio, it uses the system photo picker, which gives the app only the
photo you pick.

The full policy: [PRIVACY.md](https://github.com/own-audio/music-ios/blob/main/PRIVACY.md).
Questions: privacy@own.audio, or [an issue on GitHub](https://github.com/own-audio/music-ios/issues).

## Reporting a problem

If something goes wrong, **Settings → Logs → Share Log** gives you a text file of what the app
logged since it started, with the app and iOS versions at the top. Attach it to
[an issue](https://github.com/own-audio/music-ios/issues). The log holds no sign-in tokens,
but it can hold your server's addresses, so look it over before you post it publicly.
