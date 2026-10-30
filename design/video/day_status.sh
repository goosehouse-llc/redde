#!/bin/zsh
# day_status.sh <HH:MM> [YYYY-MM-DD]   the day video's simulator status bar at that time, Eastern (README "A day with Redde").
# With a date (the 2.3 takes pass the day they were made, a Friday, as the cards' badges say), the time
# goes in as UTC ("…Z") and is set on its own: otherwise the iPad's status bar names the wrong weekday (iOS 27.0).
S=${SIM:-"iPhone 18 Pro Max"}
if [[ -n ${2:-} ]]; then
  t=$(/bin/date -j -u -v+4H -f "%Y-%m-%d %H:%M" "$2 $1" "+%Y-%m-%dT%H:%M:00.000Z")
else
  t="2026-10-28T$1:00.000-04:00"
fi
xcrun simctl status_bar $S override --time "$t" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charging --batteryLevel 100
# Again with the time alone: set with the other values, the iPad's weekday comes out wrong (iOS 27.0)
[[ -n ${2:-} ]] && xcrun simctl status_bar $S override --time "$t"
