#!/bin/sh
# Redde's speed baseline, re-measured: smoothness (the in-app tour, scripts/smoothness.sh), launch to
# first frame, memory on a long chat and idle, and the app's size, each printed next to its limit
# (docs/perf-baseline.md says how each was taken and why the limits are what they are). Simulator
# numbers: for comparing one release with the one before it on this Mac, not a phone's.
#
#   scripts/perf-baseline.sh [--no-build] [simulator id]
#
# Builds into DerivedData-perf: Debug with -O for the simulator (the tour and the launch hook are
# DEBUG-only), Release for the simulator (launch) and Release for devices, unsigned (size). Only
# com.goosehouse.echo is installed, launched and removed. TOUR_RUNS=3 by default; LAUNCH_RUNS=5.
# Output goes to tmp/perf/.
set -u
cd "$(dirname "$0")/.."
BUILD=1; SIM=E542210E-6FA6-41C8-89D3-602684A707C8
for arg in "$@"; do
    case $arg in
        --no-build) BUILD=0 ;;
        *) SIM=$arg ;;
    esac
done
TOUR_RUNS=${TOUR_RUNS:-3}; LAUNCH_RUNS=${LAUNCH_RUNS:-5}
OUT=tmp/perf; mkdir -p "$OUT"; : > "$OUT/results.txt"
DD=DerivedData-perf
DEBUG_APP=$DD/Build/Products/Debug-iphonesimulator/Echo.app
RELSIM_APP=$DD/Build/Products/Release-iphonesimulator/Echo.app
DEVICE_APP=$DD/Build/Products/Release-iphoneos/Echo.app
BUNDLE=com.goosehouse.echo
ARGS="-setupDone YES -openToVoiceScreen NO -listenOnOpen NO -requireBiometrics NO -conversations.section sessions"

result() { echo "$1|$2" >> "$OUT/results.txt"; }   # name|value
median() { sort -n | awk '{v[NR]=$1} END {if (NR) print (NR % 2 ? v[(NR+1)/2] : (v[NR/2] + v[NR/2+1]) / 2)}'; }
fresh() {   # fresh install of $1
    xcrun simctl terminate "$SIM" $BUNDLE 2>/dev/null
    xcrun simctl uninstall "$SIM" $BUNDLE 2>/dev/null
    xcrun simctl install "$SIM" "$1"
}
footprint_mb() {   # $1 pid, $2 "now" or "peak"
    vmmap -summary "$1" 2>/dev/null | awk -v want="$2" '/^Physical footprint/ && (index($0, "(peak)") > 0) == (want == "peak") {
        v = $NF; u = substr(v, length(v)); n = substr(v, 1, length(v) - 1); print (u == "G" ? n * 1024 : u == "K" ? n / 1024 : n) }'
}

if [ $BUILD = 1 ]; then
    echo "building (Debug -O, Release simulator, Release device)…"
    for spec in "Debug|id=$SIM|SWIFT_OPTIMIZATION_LEVEL=-O" "Release|id=$SIM|" "Release|generic/platform=iOS|CODE_SIGNING_ALLOWED=NO"; do
        config=${spec%%|*}; rest=${spec#*|}; dest=${rest%%|*}; extra=${rest#*|}
        xcodebuild build -project Echo.xcodeproj -scheme Echo -configuration "$config" -destination "$dest" \
            -derivedDataPath $DD $extra > "$OUT/build.log" 2>&1 || { grep -E "error:" "$OUT/build.log" | head; exit 1; }
    done
fi

# 1. Smoothness: the tour, TOUR_RUNS fresh installs; the median of each step over the runs.
echo "smoothness: $TOUR_RUNS tours…"
rm -f tmp/smoothness/frames-*.log
scripts/smoothness.sh --no-build "$TOUR_RUNS" "$SIM" > "$OUT/smoothness.txt"
cat tmp/smoothness/frames-*.log | grep "^# tour: " | grep -v "tour: done" \
    | sed -E 's/^# tour: (.*): ([0-9]+) late, ([0-9]+) ms late \(worst ([0-9]+)\).*/\1|\2|\3|\4/' > "$OUT/tour-steps.txt"
cut -d'|' -f1 "$OUT/tour-steps.txt" | awk '!seen[$0]++' | while read -r step; do
    worst=$(grep -F "$step|" "$OUT/tour-steps.txt" | cut -d'|' -f4 | median)
    late=$(grep -F "$step|" "$OUT/tour-steps.txt" | cut -d'|' -f3 | median)
    result "tour: $step, worst frame ms" "$worst"
    result "tour: $step, ms late in all" "$late"
done

# 2. Launch to first frame. Debug -O: the app's own line (FrameMonitor, -echo.hitches): the first
# time the main run loop sleeps with a window up, measured from the process's start. Release: from
# the system log, runningboard's spawn to UIKit's "deactivation reasons: … -> 0" (within ~0.1 s of
# the first frame, checked against the Debug line on 2026-11-11). The first launch after the
# install is reported apart; the median is over the launches after it.
echo "launch: $LAUNCH_RUNS launches of each build…"
launches() {   # $1 app, $2 debug|release; prints one ms value per launch, the cold one first
    fresh "$1"
    log="$(xcrun simctl get_app_container "$SIM" $BUNDLE data)/Library/Caches/frames.log"
    r=0
    while [ $r -le "$LAUNCH_RUNS" ]; do
        xcrun simctl terminate "$SIM" $BUNDLE 2>/dev/null; sleep 2; rm -f "$log"
        pid=$(xcrun simctl launch "$SIM" $BUNDLE $ARGS -echo.hitches | awk '{print $2}')
        sleep 8
        if [ "$2" = debug ]; then
            grep -o 'first frame [0-9]* ms' "$log" 2>/dev/null | awk '{print $3}'
        else
            xcrun simctl spawn "$SIM" log show --info --last 12s --style compact \
                --predicate "(process == \"runningboardd\" AND eventMessage CONTAINS \"with pid: $pid\") OR (processID == $pid AND eventMessage CONTAINS \"deactivation reasons:\")" 2>/dev/null \
                | awk 'function t(s) { split(s, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
                       /with pid/ && !sp { sp = t($2) } / -> 0;/ && !act { act = t($2) }
                       END { if (sp && act) printf "%d\n", (act - sp) * 1000 }'
        fi
        r=$((r + 1))
    done
    xcrun simctl terminate "$SIM" $BUNDLE 2>/dev/null
}
for kind in debug release; do
    [ $kind = debug ] && app=$DEBUG_APP || app=$RELSIM_APP
    launches "$app" $kind > "$OUT/launch-$kind.txt"
    result "launch ($kind): first after install, ms" "$(head -1 "$OUT/launch-$kind.txt")"
    result "launch ($kind): median after that, ms" "$(tail -n +2 "$OUT/launch-$kind.txt" | median)"
done

# 3. Memory (Debug -O, physical footprint as vmmap reports it): idle 12 s after a fresh launch with
# nothing seeded; and the long chat (-echo.demoHeavy: 32 turns of ~10,000 characters) open at
# launch, once -echo.autoScroll has scrolled it up and back (FrameMonitor logs "autoscroll: …"):
# then, and the peak over the whole run.
echo "memory…"
fresh "$DEBUG_APP"
pid=$(xcrun simctl launch "$SIM" $BUNDLE $ARGS | awk '{print $2}')
sleep 12; result "memory: idle after launch, MB" "$(footprint_mb "$pid" now)"
fresh "$DEBUG_APP"
log="$(xcrun simctl get_app_container "$SIM" $BUNDLE data)/Library/Caches/frames.log"
pid=$(xcrun simctl launch "$SIM" $BUNDLE $ARGS -echo.hitches -echo.demoHeavy -echo.autoScroll 8 | awk '{print $2}')
i=0; until grep -q "^# autoscroll: " "$log" 2>/dev/null || [ $i -ge 60 ]; do sleep 1; i=$((i + 1)); done
sleep 1
result "memory: long chat, after scrolling, MB" "$(footprint_mb "$pid" now)"
result "memory: long chat, peak, MB" "$(footprint_mb "$pid" peak)"
xcrun simctl terminate "$SIM" $BUNDLE 2>/dev/null

# 4. Size of the Release device build: the bundle on disk, the executable, the executable stripped
# (a copy, as the App Store's thinning strips it), and a zip of the bundle (near a download).
echo "size…"
result "size: app bundle, MB" "$(du -sk "$DEVICE_APP" | awk '{printf "%.1f", $1 / 1024}')"
result "size: executable, MB" "$(stat -f %z "$DEVICE_APP/Echo" | awk '{printf "%.1f", $1 / 1048576}')"
xcrun strip -rSTx -no_code_signature_warning "$DEVICE_APP/Echo" -o "$OUT/Echo.stripped" 2>/dev/null
result "size: executable stripped, MB" "$(stat -f %z "$OUT/Echo.stripped" | awk '{printf "%.1f", $1 / 1048576}')"
rm -f "$OUT/Echo.zip"; (cd "$(dirname "$DEVICE_APP")" && zip -qry -9 "$OLDPWD/$OUT/Echo.zip" Echo.app)
result "size: bundle zipped, MB" "$(stat -f %z "$OUT/Echo.zip" | awk '{printf "%.1f", $1 / 1048576}')"

# The limits (docs/perf-baseline.md): name|limit. A value over its limit is a slowdown to look at.
cat > "$OUT/limits.txt" <<'EOF'
tour: new conversation, worst frame ms|170
tour: focus the composer, worst frame ms|530
tour: type, worst frame ms|90
tour: type, ms late in all|600
tour: send, worst frame ms|140
tour: thinking, worst frame ms|40
tour: streaming, worst frame ms|40
tour: scroll while streaming, worst frame ms|40
tour: streaming to the end, worst frame ms|130
tour: streaming to the end, ms late in all|400
tour: send again, worst frame ms|100
tour: second reply, worst frame ms|80
tour: second reply, ms late in all|550
tour: dismiss the keyboard, worst frame ms|100
tour: open the list, worst frame ms|280
tour: close the list, worst frame ms|100
tour: open the long one from the list, worst frame ms|430
tour: open a short conversation from the list, worst frame ms|165
tour: back to the long one, worst frame ms|350
tour: scroll the long one, ms late in all|50
tour: open voice mode, worst frame ms|400
tour: close voice mode, worst frame ms|120
tour: open Settings, worst frame ms|560
tour: close Settings, worst frame ms|100
launch (debug): first after install, ms|6000
launch (debug): median after that, ms|5000
launch (release): first after install, ms|6000
launch (release): median after that, ms|4700
memory: idle after launch, MB|60
memory: long chat, after scrolling, MB|155
memory: long chat, peak, MB|160
size: app bundle, MB|170
size: executable, MB|95
size: executable stripped, MB|37
size: bundle zipped, MB|72
EOF
echo
awk -F'|' 'NR == FNR { limit[$1] = $2; next }
           { l = ($1 in limit) ? limit[$1] : ""; flag = (l != "" && $2 != "" && $2 + 0 > l + 0) ? "OVER" : ($2 == "" ? "no value" : "")
             printf "  %-58s %9s %9s  %s\n", $1, $2, l, flag }
           BEGIN { printf "  %-58s %9s %9s\n", "", "now", "limit" }' "$OUT/limits.txt" "$OUT/results.txt" | tee "$OUT/report.txt"
