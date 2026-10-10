#!/usr/bin/env bash
# Runs the live JellyfinKit tests and the UI tests against the server in
# test-servers.local.env (gitignored):
#
#   JELLYFIN_HOST=https://jellyfin.example.com
#   JELLYFIN_USER=someone
#   JELLYFIN_PASSWORD=…
#   JELLYFIN_DOWNLOAD_ALBUM="a small album"     # optional
#   JELLYFIN_LYRICS_ALBUM="…"   # optional: first song has synced lyrics and a measured gain
#
# Usage: scripts/test-servers.sh [--live-only]
# One UI test only: ONLY_TESTING=testPartlyDownloadedAlbumPlaysOffline scripts/test-servers.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source ./test-servers.local.env

SIM="${SIMULATOR_ID:-$(xcrun simctl list devices booted | grep -m1 -oE '[0-9A-F-]{36}')}"
OUT="${TEST_OUTPUT:-/tmp/jelly-ios-tests}"
mkdir -p "$OUT"

echo "== live client tests"
(cd Packages/JellyfinKit && JELLYFIN_HOST="$JELLYFIN_HOST" JELLYFIN_USER="$JELLYFIN_USER" JELLYFIN_PASSWORD="$JELLYFIN_PASSWORD" \
  swift test --filter Live 2>&1 | grep -E "✘|Test run")
[[ "${1:-}" == "--live-only" ]] && exit 0

echo "== UI tests (screenshots in $OUT)"
xcodegen generate >/dev/null
TEST_RUNNER_JELLYFIN_HOST="$JELLYFIN_HOST" TEST_RUNNER_JELLYFIN_USER="$JELLYFIN_USER" TEST_RUNNER_JELLYFIN_PASSWORD="$JELLYFIN_PASSWORD" \
TEST_RUNNER_JELLYFIN_DOWNLOAD_ALBUM="${JELLYFIN_DOWNLOAD_ALBUM:-}" TEST_RUNNER_JELLYFIN_LYRICS_ALBUM="${JELLYFIN_LYRICS_ALBUM:-}" \
TEST_RUNNER_SCREENSHOT_DIR="$OUT" \
  xcodebuild test -project OwnAudioJelly.xcodeproj -scheme OwnAudioJelly -destination "id=$SIM" \
    -derivedDataPath "$OUT/DerivedData" -test-timeouts-enabled YES -default-test-execution-time-allowance 420 \
    ${ONLY_TESTING:+-only-testing:"OwnAudioJellyUITests/PlaybackSmokeTests/$ONLY_TESTING"} 2>&1 \
  | grep -E "Test Case.*(passed|failed)|\*\* TEST"
