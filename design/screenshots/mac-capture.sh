#!/bin/zsh
# Capture the Mac app's windows that mac.py turns into the Mac App Store's pictures.
#
#   design/screenshots/mac-capture.sh <raw-shots-dir>
#
# Builds a throwaway copy of the Debug Mac app, com.goosehouse.echo.shots, signed ad hoc with
# only the sandbox and the network (mac-shots.entitlements): a container of its own and no iCloud.
# Never the Debug app itself: with Sync with iCloud on there, the demo's example hosts went up to
# iCloud and on to the person's iPhone (2026-10-29), and iCloud's theme overrode the flags. Then
# opens it with the dev flags for each slot in a 1440 × 900 window and captures that window
# without its shadow. Example endpoints only. The window-id lister (winid.swift) is built for you.
set -euo pipefail
cd "${0:A:h}/../.."
RAW="${1:?raw shots dir}"; mkdir -p "$RAW"
WAIT=${WAIT:-10}   # diagrams and math finish drawing

xcodebuild build -project Echo.xcodeproj -scheme ReddeMac -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData-macshots -quiet PRODUCT_BUNDLE_IDENTIFIER=com.goosehouse.echo.shots \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  CODE_SIGN_ENTITLEMENTS="$PWD/design/screenshots/mac-shots.entitlements"
APP=DerivedData-macshots/Build/Products/Debug/Redde.app
[[ -x "$RAW/winid" ]] || swiftc -O design/screenshots/winid.swift -o "$RAW/winid"

BASE=(-setupDone YES -ApplePersistenceIgnoreState YES -openToVoiceScreen NO -listenOnOpen NO -requireBiometrics NO -echo.demoHosts
      -echo.windowSize 1440x900 -conversations.section sessions)
FAST=(-transport chatCompletions)
BOTS=(-echo.demoProjects -echo.demoBots -echo.clearDrafts -displayName Redde -mutes "<>")

shot() {   # name args...
  local name="$1"; shift
  # Through Launch Services, then once more: opened from its binary, or opened only once, an ad hoc
  # copy shows its menus and no window; the second open is a reopen, which makes one.
  open -n "$APP" --args "${BASE[@]}" "$@"; sleep 3; open "$APP"
  sleep $WAIT
  local pid=$(pgrep -f "$PWD/$APP/Contents/MacOS/Redde" | head -1)
  local win=$("$RAW/winid" $pid | awk '$2 == "1440x900" { print $1; exit }')
  [[ -n "$win" ]] || { echo "$name: no 1440x900 window"; "$RAW/winid" $pid; kill $pid; return 1; }
  screencapture -x -o -l"$win" "$RAW/$name.png"
  kill $pid; sleep 2
  echo "$name"
}

shot mac-work     -echo.demo -echo.demoTwo -echo.demoLibrary -theme paper -appearance light "${FAST[@]}"
shot mac-bots     -echo.demoLibrary -echo.demoMarks -theme claudeCode -appearance dark "${BOTS[@]}"
WAIT=30 shot mac-crew -echo.demoLibrary -echo.openGroup -echo.demoRound -theme claudeCode -appearance dark "${BOTS[@]}"
shot mac-rich     -echo.demo -echo.demoLibrary -theme claudeCode -appearance dark "${FAST[@]}"
shot mac-settings -echo.demo -echo.demoLibrary -echo.screen setup -theme standard -appearance light "${FAST[@]}"
