#!/bin/sh
# How smooth Redde is, measured: the app goes through what people do in it by itself
# (`-echo.tour`, ContentView.runTour) while it logs every frame it makes late (`-echo.hitches`,
# FrameMonitor), and prints for each step how many frames came late, how late in all, the worst
# one, and how much of a core it took. Replies stream from a stand-in model on this Mac
# (scripts/smooth-model.py). An optimized Debug build on a simulator: these are this Mac's
# numbers, for a change against the one before it, not a phone's.
#
#   scripts/smoothness.sh [--no-build] [--send] [runs] [simulator id]
#
# --send stops once the reply has streamed. Output goes to tmp/smoothness/.
set -u
cd "$(dirname "$0")/.."
BUILD=1; TOUR=""; RUNS=1; SIM=E542210E-6FA6-41C8-89D3-602684A707C8
for arg in "$@"; do
    case $arg in
        --no-build) BUILD=0 ;;
        --send) TOUR=send ;;
        [0-9]|[0-9][0-9]) RUNS=$arg ;;
        *) SIM=$arg ;;
    esac
done
OUT=tmp/smoothness
mkdir -p "$OUT"
if [ $BUILD = 1 ]; then
    xcodebuild build -project Echo.xcodeproj -scheme Echo -configuration Debug -destination "id=$SIM" \
        -derivedDataPath DerivedData-perf SWIFT_OPTIMIZATION_LEVEL=-O > "$OUT/build.log" 2>&1 \
        || { grep -E "error:" "$OUT/build.log" | head; exit 1; }
fi
PORT=8799
lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 || {
    PORT=$PORT /usr/bin/python3 scripts/smooth-model.py > "$OUT/model.log" 2>&1 &
    MODEL=$!
    trap 'kill $MODEL 2>/dev/null' EXIT
    sleep 1
}
APP=DerivedData-perf/Build/Products/Debug-iphonesimulator/Echo.app
run=1
while [ $run -le $RUNS ]; do
    # A fresh install each time: the tour's demo conversations are seeded again at launch.
    xcrun simctl terminate "$SIM" com.goosehouse.echo 2>/dev/null
    xcrun simctl uninstall "$SIM" com.goosehouse.echo 2>/dev/null
    xcrun simctl install "$SIM" "$APP"
    xcrun simctl launch "$SIM" com.goosehouse.echo -setupDone YES -openToVoiceScreen NO -listenOnOpen NO -requireBiometrics NO \
        -conversations.section sessions -fastLaneURL "http://127.0.0.1:$PORT" -fastLaneModel test \
        -echo.hitches -echo.demoHeavy 24 -echo.demoLibrary -echo.tour $TOUR > /dev/null
    LOG="$(xcrun simctl get_app_container "$SIM" com.goosehouse.echo data)/Library/Caches/frames.log"
    i=0
    until grep -q "^# tour: done" "$LOG" 2>/dev/null || [ $i -ge 180 ]; do sleep 1; i=$((i + 1)); done
    sleep 1
    cp "$LOG" "$OUT/frames-$run.log"
    echo "run $run"
    grep "^# tour: " "$LOG" | grep -v "tour: done" \
        | sed -E 's/^# tour: (.*): ([0-9]+) late, ([0-9]+) ms late \(worst ([0-9]+)\), cpu ([0-9]+) ms \(([0-9]+)% of a core\) over ([0-9.]+) s.*/\1|\2|\3|\4|\6/' \
        | awk -F'|' 'BEGIN { printf "  %-44s %5s %7s %6s %5s\n", "step", "late", "ms late", "worst", "core" }
                     { printf "  %-44s %5s %7s %6s %4s%%\n", $1, $2, $3, $4, $5 }' | tee -a "$OUT/table.txt"
    xcrun simctl terminate "$SIM" com.goosehouse.echo 2>/dev/null
    run=$((run + 1))
done
