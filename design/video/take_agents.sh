#!/bin/zsh
# take_agents.sh <name> <TestName>   one take of the agents video (README "Agents, for Reddit (2.6)"):
# Redde reinstalled fresh, the status bar at 9:41, the UI test recorded. KOKORO_URL, when set, is
# handed to the test (the voice round speaks through it).
set -u
export SIM=${SIM:-DCA5C0E8-5B1A-4AB7-A901-5525B2CBE6C5} DD=${DD:-DerivedData-agents}
V=${0:A:h}
xcrun simctl uninstall $SIM com.goosehouse.echo 2>/dev/null
xcrun simctl status_bar $SIM override --time "2026-11-14T09:41:00.000-05:00" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
[[ -n ${KOKORO_URL:-} ]] && export TEST_RUNNER_KOKORO_URL=$KOKORO_URL
$V/record.sh --test $1 $2
