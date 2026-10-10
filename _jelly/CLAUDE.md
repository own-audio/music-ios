# CLAUDE.md — jelly-ios

Open-source (MPL-2.0) native iOS music player for Jellyfin, published by own.audio. The repo
is **public** — write everything for strangers to read.

- Work phase by phase from `IMPLEMENTATION_PLAN.md`; tick phases there.
- Every change gets a `CHANGELOG.md` entry under `[Unreleased]`.
- **No own.audio internals in this repo**: no references to the closed repos, internal
  hosts, team IDs or credentials. Comments explain why, for an outside reader.
- own.audio may appear as one mention, never as a funnel.
- Screens and behaviour follow own.audio for Subsonic (`../subsonic-ios`); keep the two alike
  unless Jellyfin differs (the plan lists where).

## Layout

- `Packages/JellyfinKit/` — the Jellyfin client and Keychain server store; Foundation only,
  written by hand (no generated SDK).
- `own-audio/player-engine` (product `MusicEngine`) — the shared player, a SwiftPM dependency.
  To change it alongside the app, point `project.yml` at `path: ../player-engine` while
  working, tag a release there, switch back to the URL. Never commit the path form.

## Tests

```bash
cd Packages/JellyfinKit && swift test                       # stubbed
set -a; source ../../test-servers.local.env; set +a
swift test --filter Live                                     # against a real server
```

`test-servers.local.env` (gitignored) holds `JELLYFIN_HOST`, `JELLYFIN_USER`,
`JELLYFIN_PASSWORD`. Never commit them.
