#!/usr/bin/env bash
# Runs the live client tests and the UI tests against every server in test-servers.local.env
# (gitignored). Each server is a block of variables:
#
#   NAVIDROME_HOST=https://music.example.com          # a Subsonic server
#   NAVIDROME_USER=someone
#   NAVIDROME_PASSWORD=…
#   NAVIDROME_DOWNLOAD_ALBUM="a small album"        # optional
#   NAVIDROME_LYRICS_ALBUM="…"   # optional: first song has synced lyrics and ReplayGain -6.5 dB
#
#   OWNAUDIO_HOST=https://demo.example.com             # an own.audio server
#   OWNAUDIO_EMAIL=guest@example.com
#   OWNAUDIO_ACCOUNT_PASSWORD=…                        # used to fetch the Subsonic key
#   OWNAUDIO_DOWNLOAD_ALBUM="a small album"           # optional
#
#   JELLYFIN_HOST=https://jellyfin.example.com
#   JELLYFIN_USER=someone
#   JELLYFIN_PASSWORD=…
#   JELLYFIN_DOWNLOAD_ALBUM="a small album"           # optional
#
# Usage: scripts/test-servers.sh [navidrome|ownaudio|jellyfin|demo] [--live-only]
# One UI test only: ONLY_TESTING=testPartlyDownloadedAlbumPlaysOffline scripts/test-servers.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source ./test-servers.local.env

SIM="${SIMULATOR_ID:-$(xcrun simctl list devices booted | grep -m1 -oE '[0-9A-F-]{36}')}"
OUT="${TEST_OUTPUT:-/tmp/music-ios-tests}"
mkdir -p "$OUT"
only="${1:-all}"
live_only="${2:-}"

ui_tests() { # name host user password download-album lyrics-album
  local name=$1 host=$2 user=$3 password=$4 album=${5:-} lyrics=${6:-}
  echo "== $name: UI tests (screenshots in $OUT/$name)"
  mkdir -p "$OUT/$name"
  xcodegen generate >/dev/null
  TEST_RUNNER_SERVER_HOST="$host" TEST_RUNNER_SERVER_USER="$user" TEST_RUNNER_SERVER_PASSWORD="$password" \
  TEST_RUNNER_SERVER_DOWNLOAD_ALBUM="$album" TEST_RUNNER_SERVER_LYRICS_ALBUM="$lyrics" \
  TEST_RUNNER_SCREENSHOT_DIR="$OUT/$name" \
    xcodebuild test -project OwnAudioMusic.xcodeproj -scheme OwnAudioMusic -destination "id=$SIM" \
      -derivedDataPath "$OUT/DerivedData" -test-timeouts-enabled YES -default-test-execution-time-allowance 420 \
      ${ONLY_TESTING:+-only-testing:"OwnAudioMusicUITests/PlaybackSmokeTests/$ONLY_TESTING"} 2>&1 \
    | grep -E "Test Case.*(passed|failed)|\*\* TEST" || true
}

subsonic_live() { # name host user password
  echo "== $1: live Subsonic client tests"
  (cd Packages/SubsonicKit && SUBSONIC_HOST="$2" SUBSONIC_USER="$3" SUBSONIC_PASSWORD="$4" \
    swift test --filter Live 2>&1 | grep -E "✘|Test run")
}

if [[ "$only" == all || "$only" == navidrome ]]; then
  subsonic_live navidrome "$NAVIDROME_HOST" "$NAVIDROME_USER" "$NAVIDROME_PASSWORD"
  [[ "$live_only" == "--live-only" ]] || ui_tests navidrome "$NAVIDROME_HOST" "$NAVIDROME_USER" "$NAVIDROME_PASSWORD" "${NAVIDROME_DOWNLOAD_ALBUM:-}" "${NAVIDROME_LYRICS_ALBUM:-}"
fi

if [[ "$only" == all || "$only" == ownaudio ]]; then
  # own.audio's Subsonic API takes a per-user key, not the account password; a demo server
  # that resets nightly issues a new one each day.
  token=$(curl -sf -A music-ios-tests -X POST "$OWNAUDIO_HOST/api/v1/auth/login" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$OWNAUDIO_EMAIL\",\"password\":\"$OWNAUDIO_ACCOUNT_PASSWORD\"}" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
  key=$(curl -sf -A music-ios-tests "$OWNAUDIO_HOST/api/v1/users/me/subsonic-key" -H "Authorization: Bearer $token" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['api_key'])")
  subsonic_live ownaudio "$OWNAUDIO_HOST" "$OWNAUDIO_EMAIL" "$key"
  # The app takes the account password and fetches the key itself.
  [[ "$live_only" == "--live-only" ]] || ui_tests ownaudio "$OWNAUDIO_HOST" "$OWNAUDIO_EMAIL" "$OWNAUDIO_ACCOUNT_PASSWORD" "${OWNAUDIO_DOWNLOAD_ALBUM:-}"
fi

if [[ "$only" == all || "$only" == jellyfin ]]; then
  echo "== jellyfin: live client tests"
  (cd Packages/JellyfinKit && JELLYFIN_HOST="$JELLYFIN_HOST" JELLYFIN_USER="$JELLYFIN_USER" JELLYFIN_PASSWORD="$JELLYFIN_PASSWORD" \
    swift test --filter Live 2>&1 | grep -E "✘|Test run")
  [[ "$live_only" == "--live-only" ]] || ui_tests jellyfin "$JELLYFIN_HOST" "$JELLYFIN_USER" "$JELLYFIN_PASSWORD" "${JELLYFIN_DOWNLOAD_ALBUM:-}"
fi

if [[ "$only" == all || "$only" == demo ]] && [[ "$live_only" != "--live-only" ]]; then
  echo "== demo: Try the Demo Library"
  xcodegen generate >/dev/null
  TEST_RUNNER_DEMO=1 xcodebuild test -project OwnAudioMusic.xcodeproj -scheme OwnAudioMusic -destination "id=$SIM" \
    -derivedDataPath "$OUT/DerivedData" -only-testing:OwnAudioMusicUITests/DemoTests 2>&1 \
    | grep -E "Test Case.*(passed|failed)|\*\* TEST" || true
fi
