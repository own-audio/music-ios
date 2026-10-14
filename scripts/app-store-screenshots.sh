#!/usr/bin/env bash
# Takes the App Store screenshots on the store's required sizes, in English and Czech. From
# test-servers.local.env: SCREENSHOT_HOST, an own.audio server holding only the demo library
# (seeded by audio2's deploy/demo/seed.py, whose music and pictures may be shown publicly), and
# SCREENSHOT_EMAIL / SCREENSHOT_PASSWORD, the account that owns that music and runs its
# household; the Navidrome and Jellyfin servers there are added beside it.
#
# Usage: scripts/app-store-screenshots.sh   → AppStore/screenshots/<language>/<device>/
set -euo pipefail
cd "$(dirname "$0")/.."
source ./test-servers.local.env

DEVICES=("iPhone 17 Pro Max" "iPad Pro 13-inch (M5)")
[[ -n "${ONLY_DEVICE:-}" ]] && DEVICES=("$ONLY_DEVICE")   # e.g. ONLY_DEVICE="iPhone 17 Pro Max" LANGUAGES=en
ALBUM="${SCREENSHOT_ALBUM:-The Run}"
IDENTIFY_ALBUM="${SCREENSHOT_IDENTIFY_ALBUM:-Jazz Sampler}"
DERIVED="${TEST_OUTPUT:-/tmp/music-ios-tests}/DerivedData"

xcodegen generate >/dev/null
for device in "${DEVICES[@]}"; do
  id=$(xcrun simctl list devices available | grep -F "$device (" | head -1 | grep -oE '[0-9A-F-]{36}')
  xcrun simctl boot "$id" 2>/dev/null || true
  xcrun simctl status_bar "$id" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  for language in ${LANGUAGES:-en cs}; do
    out="AppStore/screenshots/$language/$device"
    mkdir -p "$out"
    echo "== $device, $language"
    TEST_RUNNER_SERVER_HOST="${SCREENSHOT_HOST:-$OWNAUDIO_HOST}" TEST_RUNNER_SERVER_USER="${SCREENSHOT_EMAIL:-$OWNAUDIO_EMAIL}" \
    TEST_RUNNER_SERVER_PASSWORD="${SCREENSHOT_PASSWORD:-$OWNAUDIO_ACCOUNT_PASSWORD}" \
    TEST_RUNNER_NAVIDROME_HOST="${NAVIDROME_HOST:-}" TEST_RUNNER_NAVIDROME_USER="${NAVIDROME_USER:-}" TEST_RUNNER_NAVIDROME_PASSWORD="${NAVIDROME_PASSWORD:-}" \
    TEST_RUNNER_JELLYFIN_HOST="${JELLYFIN_HOST:-}" TEST_RUNNER_JELLYFIN_USER="${JELLYFIN_USER:-}" TEST_RUNNER_JELLYFIN_PASSWORD="${JELLYFIN_PASSWORD:-}" \
    TEST_RUNNER_SCREENSHOT_DIR="$PWD/$out" TEST_RUNNER_SCREENSHOT_LANGUAGE="$language" TEST_RUNNER_SCREENSHOT_ALBUM="$ALBUM" \
    TEST_RUNNER_SCREENSHOT_IDENTIFY_ALBUM="$IDENTIFY_ALBUM" \
      xcodebuild test -project OwnAudioMusic.xcodeproj -scheme OwnAudioMusic -destination "id=$id" \
        -derivedDataPath "$DERIVED" -only-testing:OwnAudioMusicUITests/AppStoreScreenshots \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 600 2>&1 \
      | grep -E "Test Case.*(passed|failed)|\*\* TEST"
  done
  xcrun simctl status_bar "$id" clear
done
