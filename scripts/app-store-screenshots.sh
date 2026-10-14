#!/usr/bin/env bash
# Takes the App Store screenshots on the store's required sizes, in English and Czech, from
# the own.audio server in test-servers.local.env (its demo music may be shown publicly).
#
# Usage: scripts/app-store-screenshots.sh   → AppStore/screenshots/<language>/<device>/
set -euo pipefail
cd "$(dirname "$0")/.."
source ./test-servers.local.env

DEVICES=("iPhone 17 Pro Max" "iPad Pro 13-inch (M5)")
ALBUM="${SCREENSHOT_ALBUM:-Classical Sampler}"
DERIVED="${TEST_OUTPUT:-/tmp/music-ios-tests}/DerivedData"

xcodegen generate >/dev/null
for device in "${DEVICES[@]}"; do
  id=$(xcrun simctl list devices available | grep -F "$device (" | head -1 | grep -oE '[0-9A-F-]{36}')
  xcrun simctl boot "$id" 2>/dev/null || true
  xcrun simctl status_bar "$id" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  for language in en cs; do
    out="AppStore/screenshots/$language/$device"
    mkdir -p "$out"
    echo "== $device, $language"
    TEST_RUNNER_SERVER_HOST="$OWNAUDIO_HOST" TEST_RUNNER_SERVER_USER="$OWNAUDIO_EMAIL" TEST_RUNNER_SERVER_PASSWORD="$OWNAUDIO_ACCOUNT_PASSWORD" \
    TEST_RUNNER_SCREENSHOT_DIR="$PWD/$out" TEST_RUNNER_SCREENSHOT_LANGUAGE="$language" TEST_RUNNER_SCREENSHOT_ALBUM="$ALBUM" \
      xcodebuild test -project OwnAudioMusic.xcodeproj -scheme OwnAudioMusic -destination "id=$id" \
        -derivedDataPath "$DERIVED" -only-testing:OwnAudioMusicUITests/AppStoreScreenshots \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 300 2>&1 \
      | grep -E "Test Case.*(passed|failed)|\*\* TEST"
  done
  xcrun simctl status_bar "$id" clear
done
