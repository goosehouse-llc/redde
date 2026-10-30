#!/bin/zsh
# day_status.sh <HH:MM>   the day video's simulator status bar at that time (README "A day with Redde")
S=${SIM:-"iPhone 18 Pro Max"}
xcrun simctl status_bar $S override --time "2026-10-28T$1:00.000-04:00" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charging --batteryLevel 100
