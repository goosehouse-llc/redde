#!/bin/zsh
# take23.sh <HH:MM> <name> <TestName>   one take of the 2.3 day (README "A day with Redde, 2.3"):
# Redde reinstalled fresh, the status bar at the scene's time, the UI test recorded.
set -u
export SIM=${SIM:-395C295F-FB35-4596-9100-4CE66EE9E725} DD=${DD:-DerivedData-video}
V=${0:A:h}
# KEEP=1 keeps Redde installed (the iPad's first launch after an install takes a minute or more)
[[ ${KEEP:-0} == 1 ]] || xcrun simctl uninstall $SIM com.goosehouse.echo 2>/dev/null
$V/day_status.sh $1 2026-10-30
$V/record.sh --test $2 $3
