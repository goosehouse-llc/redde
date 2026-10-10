#!/bin/zsh
# Draw what CarPlay makes of Redde's screens, without a car and without the CarPlay window:
# CarPlay's own views are given the app's templates in a simulator and written out as pictures
# (EchoTests/CarPlayPreviewTests.swift says how, and what a preview leaves out).
#
#   scripts/carplay-preview.sh [folder] [sizes]
#
# folder   where the PNG files and measurements.txt go (default: tmp/carplay-preview)
# sizes    car screens in points, e.g. 400x240,960x540 (default: 400x240,640x360,800x480)
#
# The simulator has to run iOS 26.4 or later, where the voice card got its bar and its action
# buttons; name another with REDDE_PREVIEW_SIMULATOR.
set -euo pipefail
cd "${0:A:h}/.."

OUT="${1:-tmp/carplay-preview}"
SIZES="${2:-400x240,640x360,800x480}"
SIM="${REDDE_PREVIEW_SIMULATOR:-iPhone 18 Pro Max}"
mkdir -p "$OUT"
OUT="${OUT:A}"
LOG="$OUT/xcodebuild.log"

xcodegen generate --quiet
DEST="platform=iOS Simulator,name=$SIM"
xcodebuild build-for-testing -project Echo.xcodeproj -scheme Echo -destination "$DEST" -derivedDataPath DerivedData-tests > "$LOG" 2>&1 \
  || { grep -E " error: " "$LOG" | cut -c1-200; echo "the build failed; see $LOG"; exit 1; }

# The first launch of the test runner after a build often hangs here, and xcodebuild often stays
# up after the tests are over: go by its log, stop it, and try again if no test ran.
for attempt in 1 2 3; do
  xcrun simctl terminate "$SIM" com.goosehouse.echo > /dev/null 2>&1 || true
  TEST_RUNNER_REDDE_CARPLAY_PREVIEW="$OUT" TEST_RUNNER_REDDE_CARPLAY_SIZES="$SIZES" \
    xcodebuild test-without-building -project Echo.xcodeproj -scheme Echo -destination "$DEST" \
    -derivedDataPath DerivedData-tests -only-testing:EchoTests/CarPlayPreviewTests > "$LOG" 2>&1 &
  RUN=$!
  for _ in {1..36}; do
    grep -qE "Test run with|hung before" "$LOG" 2>/dev/null && break
    kill -0 $RUN 2>/dev/null || break
    sleep 5
  done
  sleep 2
  kill $RUN 2>/dev/null || true
  grep -q "Test run with" "$LOG" && break
  echo "the test runner didn't start (try $attempt); once more"
done
grep -E "Test run with|recorded an issue" "$LOG" | cut -c1-200 || true
echo "Pictures in $OUT ($(ls "$OUT" | grep -c '\.png$') files); measurements in $OUT/measurements.txt"
