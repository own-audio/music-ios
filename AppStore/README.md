# App Store listing

Text per language (`en-US/`, `cs/`), in the store's fields, and screenshots taken by
`scripts/app-store-screenshots.sh` from a server whose music may be shown publicly.

Store details that live in App Store Connect:

- **Category:** Music.
- **Age rating:** 4+ (the app shows whatever the user's own server holds).
- **Price:** free, no in-app purchases.
- **App privacy:** Data Not Collected. The app sends nothing to anyone but the servers the
  user adds (and Apple or Google for a sign-in the user chooses); see `PRIVACY.md`.
- **Privacy policy URL:** https://github.com/own-audio/music-ios/blob/main/PRIVACY.md
- **Support URL:** https://github.com/own-audio/music-ios/issues
- **Marketing URL:** https://www.own.audio
- **Review notes:** no account is needed to try the app: the welcome screen's "Try the Demo
  Library" signs in to the public own.audio demo server (demopi.own.audio) by itself. For a
  Subsonic or Jellyfin server, the reviewer needs one of their own. CarPlay needs the CarPlay
  audio entitlement.

Limits: name and subtitle 30 characters, keywords 100, promotional text 170, description
4000.

CarPlay is left out of the description until it has been checked on a CarPlay screen and the
entitlement is granted.
