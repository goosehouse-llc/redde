#!/bin/zsh
# Capture the raw simulator shots that compose.py and pano.py turn into App Store screenshots.
#
#   design/screenshots/capture.sh <raw-shots-dir>
#
# Builds the Debug app, then launches it on the iPhone 17 Pro Max (6.9") and iPad Pro 13-inch
# simulators with the dev flags for each slot and a 9:41 status bar. Example endpoints only.
set -euo pipefail
cd "${0:A:h}/../.."
RAW="${1:?raw shots dir}"; mkdir -p "$RAW"
BUNDLE=com.goosehouse.echo
PHONE="${PHONE:-iPhone 17 Pro Max}"   # a UDID works too
PAD="${PAD:-iPad Pro 13-inch (M5)}"   # pass a UDID when two simulators share the name
WAIT=9   # diagrams and math finish drawing

xcodebuild -project Echo.xcodeproj -scheme Echo -destination "generic/platform=iOS Simulator" \
  -derivedDataPath DerivedData -quiet build
APP=DerivedData/Build/Products/Debug-iphonesimulator/Echo.app

BASE=(-setupDone YES -openToVoiceScreen NO -listenOnOpen NO -requireBiometrics NO -echo.demoHosts)
FAST=(-transport chatCompletions)      # chat shots: fast-lane footer metrics
LEDGER=(-transport hermesSessions)     # setup shots: the gateway option selected

prepare() {   # device
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b >/dev/null
  xcrun simctl status_bar "$1" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi
  xcrun simctl install "$1" "$APP"
}

shot() {   # device name args...
  local dev="$1" name="$2"; shift 2
  xcrun simctl terminate "$dev" $BUNDLE 2>/dev/null || true
  xcrun simctl launch "$dev" $BUNDLE "${BASE[@]}" "$@" >/dev/null
  sleep $WAIT
  xcrun simctl io "$dev" screenshot "$RAW/$name.png" >/dev/null
  echo "$name"
}

prepare "$PHONE"
shot "$PHONE" ph-chat-dark -echo.demo -theme standard -appearance dark "${FAST[@]}"
# Pano left half: the Hermes theme, gold on near-black.
shot "$PHONE" ph-chat-hermes -echo.demo -theme githubDark -appearance dark "${FAST[@]}"
# Voice mode mid-listen (-echo.voiceDemo): the simulator has no mic, so the waveform is posed.
shot "$PHONE" ph-voice     -echo.demo -echo.voiceView -echo.voiceDemo -voiceOrb waveform -theme slate -appearance dark "${FAST[@]}"
# Work slot: two exchanges, so the frame is full and a subagent row stays in view under the header.
shot "$PHONE" ph-work      -echo.demo -echo.demoTwo -theme paper -appearance light "${FAST[@]}"
# Rich ends on the kitchen reply (code, checklist, table); the panorama already shows the diagram.
shot "$PHONE" ph-diagram   -echo.demo -echo.demoTwo -theme claudeCode -appearance dark "${FAST[@]}"
shot "$PHONE" ph-settings  -echo.demo -echo.screen setup -theme standard -appearance light "${LEDGER[@]}"
# "Make it yours": Settings with the App icon grid open.
shot "$PHONE" ph-chat      -echo.demo -echo.screen settings -echo.expandAppIcons -theme standard -appearance light "${FAST[@]}"
# Website only: the Kanban board (demo cards, no server) and typing with the keyboard up.
shot "$PHONE" ph-kanban    -echo.demo -echo.demoKanban -echo.screen sessions -echo.section kanban -theme claudeCode -appearance dark "${FAST[@]}"
# A headless simulator hides the software keyboard; turn that off for this one shot.
KB=(xcrun simctl spawn "$PHONE" defaults write com.apple.keyboard.preferences)
"${KB[@]}" AutomaticMinimizationEnabled -bool false; "${KB[@]}" HardwareKeyboardLastSeen -bool false
shot "$PHONE" ph-type      -echo.demo -echo.demoTwo -echo.draft "Push the countertop crew to the 24th and draft a note to the contractor" -theme claudeCode -appearance dark "${FAST[@]}"
"${KB[@]}" AutomaticMinimizationEnabled -bool true; "${KB[@]}" HardwareKeyboardLastSeen -bool true

prepare "$PAD"
shot "$PAD" pad-default-dark -echo.demo -echo.demoLibrary -theme standard -appearance dark "${FAST[@]}"
# Pano left half: the Hermes theme, gold on near-black.
shot "$PAD" pad-hermes       -echo.demo -echo.demoLibrary -theme githubDark -appearance dark "${FAST[@]}"
shot "$PAD" pad-voice        -echo.demo -echo.voiceView -echo.voiceDemo -voiceOrb waveform -theme slate -appearance dark "${FAST[@]}"
# Same as the phone work slot: one exchange left most of the detail pane empty.
shot "$PAD" pad-work         -echo.demo -echo.demoTwo -echo.demoLibrary -theme paper -appearance light "${FAST[@]}"
shot "$PAD" pad-dark         -echo.demo -echo.demoTwo -echo.demoLibrary -theme claudeCode -appearance dark "${FAST[@]}"
# iPad keeps the fast lane here: with the gateway selected the sidebar tries the example host and shows an error.
shot "$PAD" pad-settings     -echo.demo -echo.demoLibrary -echo.screen setup -theme standard -appearance light "${FAST[@]}"
shot "$PAD" pad-split        -echo.demo -echo.demoLibrary -echo.screen settings -echo.expandAppIcons -theme standard -appearance light "${FAST[@]}"
