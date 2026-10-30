#!/bin/zsh
# Capture the raw simulator shots that compose.py and pano.py turn into App Store screenshots.
#
#   design/screenshots/capture.sh <raw-shots-dir>
#   ONLY=pad design/screenshots/capture.sh <raw-shots-dir>   (or ONLY=phone)
#
# Builds the Debug app, then launches it on the iPhone 18 Pro Max (6.9") and iPad Pro 13-inch
# simulators with the dev flags for each slot and a 9:41 status bar. Example endpoints only.
# The 2.3 set (2026-10-30) was taken on simulators of its own, made for it on iOS 27.0:
#   PHONE=<iPhone 17 Pro Max UDID> PAD=<iPad Pro 13-inch (M5) UDID> design/screenshots/capture.sh <raw>
# Its Leave-By banner needs notifications allowed on each first: run PromoVideoUITests.testDayLeave
# there once (it taps Allow), as the README says.
set -euo pipefail
cd "${0:A:h}/../.."
RAW="${1:?raw shots dir}"; mkdir -p "$RAW"
BUNDLE=com.goosehouse.echo
PHONE="${PHONE:-iPhone 18 Pro Max}"   # a UDID works too
PAD="${PAD:-iPad Pro 13-inch (M5)}"   # pass a UDID when two simulators share the name
WAIT=9   # diagrams and math finish drawing

xcodebuild -project Echo.xcodeproj -scheme Echo -destination "generic/platform=iOS Simulator" \
  -derivedDataPath DerivedData -quiet build
APP=DerivedData/Build/Products/Debug-iphonesimulator/Echo.app

# Setup is marked done in the app's defaults (prepare), not with -setupDone YES on the command line,
# which keeps the demo flags from taking.
BASE=(-openToVoiceScreen NO -listenOnOpen NO -requireBiometrics NO -echo.demoHosts)
# iPad: the sidebar on Chats and the chat in the wide pane, whatever was last picked there.
CHATS=(-conversations.section sessions)
FAST=(-transport chatCompletions)      # chat shots: fast-lane footer metrics
LEDGER=(-transport hermesSessions)     # setup shots: the gateway option selected

prepare() {   # device
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b >/dev/null
  xcrun simctl status_bar "$1" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi
  xcrun simctl install "$1" "$APP"
  xcrun simctl spawn "$1" defaults write com.goosehouse.echo setupDone -bool YES
  # A fresh install's first launch is still setting up (the iPad sidebar showed a key prompt), so
  # throw one away. With the demo conversation, so its diagram and math have been drawn once:
  # drawn for the first time they arrive late, and the shot caught the transcript short of its end.
  xcrun simctl launch "$1" $BUNDLE "${BASE[@]}" "${FAST[@]}" -echo.demo >/dev/null; sleep $WAIT
}

shot() {   # device name args...
  local dev="$1" name="$2"; shift 2
  xcrun simctl terminate "$dev" $BUNDLE 2>/dev/null || true
  xcrun simctl launch "$dev" $BUNDLE "${BASE[@]}" "$@" >/dev/null
  sleep ${PAUSE:-$WAIT}
  xcrun simctl io "$dev" screenshot "$RAW/$name.png" >/dev/null
  echo "$name"
}

# The status bar at the Mac's clock (24-hour, so the iPad says PM), for screens that show the time
# of day themselves (the weather, a briefing, a leaving time); `clock 9:41` puts it back.
clock() {   # device [time]
  xcrun simctl status_bar "$1" clear
  xcrun simctl status_bar "$1" override --time "${2:-$(date +%H:%M)}" --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi
}

# 2.3's "Ahead of your day": the chat list's ideas and briefings, and the Leave-By Alert's banner
# over them (-echo.demoLeaveBy 3). When the banner lands depends on how busy the Mac is (6 to 20
# seconds after launch on 2026-10-30), so this takes a burst into <raw>/<name>-burst/: copy the one
# with the banner in it to <raw>/<name>.png (the last one is put there to begin with).
ahead() {   # device name args...
  local dev="$1" name="$2"; shift 2
  clock "$dev"
  PAUSE=4 shot "$dev" "$name" -echo.demoIdeas -echo.demoBriefings -displayName Sol -theme standard -appearance dark \
    -echo.demoLeaveBy 3 "$@"
  mkdir -p "$RAW/$name-burst"
  for i in {01..24}; do xcrun simctl io "$dev" screenshot "$RAW/$name-burst/$i.png" >/dev/null 2>&1; sleep 0.4; done
  cp "$RAW/$name-burst/24.png" "$RAW/$name.png"
  echo "$name: pick the picture with the banner from $name-burst"
  clock "$dev" 9:41
}

# ONLY=phone or ONLY=pad retakes one device's shots into a folder that has the other's.
if [[ "${ONLY:-}" != pad ]]; then
prepare "$PHONE"
shot "$PHONE" ph-chat-dark -echo.demo -theme standard -appearance dark "${FAST[@]}"
# Pano left half: the Hermes theme, gold on near-black.
shot "$PHONE" ph-chat-hermes -echo.demo -theme githubDark -appearance dark "${FAST[@]}"
# Voice mode mid-listen (-echo.voiceDemo): the simulator has no mic, so the waveform is posed.
shot "$PHONE" ph-voice     -echo.demo -echo.voiceView -echo.voiceDemo -voiceOrb darkGlass -theme slate -appearance dark "${FAST[@]}"
# Work slot: two exchanges, so the frame is full and a subagent row stays in view under the header.
shot "$PHONE" ph-work      -echo.demo -echo.demoTwo -theme paper -appearance light "${FAST[@]}"
# Rich ends on the kitchen reply (code, checklist, table); the panorama already shows the diagram.
shot "$PHONE" ph-diagram   -echo.demo -echo.demoTwo -theme claudeCode -appearance dark "${FAST[@]}"
shot "$PHONE" ph-settings  -echo.demo -echo.screen setup -theme standard -appearance light "${LEDGER[@]}"
# "Make it yours": Settings with the App icon grid open.
shot "$PHONE" ph-chat      -echo.demo -echo.screen settings -echo.expandAppIcons -theme standard -appearance light "${FAST[@]}"
# 1.8: the agent having used the phone (the Phone tools slot; its two insets, the timer on the
# Lock Screen and the widget, come from PromoVideoUITests.testToolsShotInsets on an iOS 26.3
# simulator: see README). 1.7: the Hermes server's own screens on sample data.
shot "$PHONE" ph-phone     -echo.demoPhoneShot -theme standard -appearance dark "${FAST[@]}"
shot "$PHONE" ph-gateway   -echo.demo -echo.demoGateway -echo.screen gateway -theme standard -appearance dark "${FAST[@]}"
shot "$PHONE" ph-files     -echo.demo -echo.demoFiles -echo.screen files -theme standard -appearance light "${FAST[@]}"
# 2.3: ahead of your day, the day's timeline, answer cards (the weather, and the places and the
# email that compose.py cuts out and sets over a screen), and an approval in plain words.
ahead "$PHONE" ph-ahead -echo.demoProjects -echo.demoBots -echo.screen sessions -transport hermesServe
CARDS=(-theme standard -appearance dark "${FAST[@]}")
shot "$PHONE" ph-day       -echo.demoAgenda tomorrow "${CARDS[@]}"
clock "$PHONE"
shot "$PHONE" ph-weather   -echo.demoCards weather "${CARDS[@]}"
shot "$PHONE" ph-places    -echo.demoCards places "${CARDS[@]}"
clock "$PHONE" 9:41
shot "$PHONE" ph-review    -echo.demoAsks -echo.demoAsksReviewOnly "${CARDS[@]}"
shot "$PHONE" ph-approve   -echo.demoApprovalCard skill "${CARDS[@]}"
# Website only: the Kanban board (demo cards, no server) and typing with the keyboard up.
shot "$PHONE" ph-kanban    -echo.demo -echo.demoKanban -echo.screen sessions -echo.section kanban -theme claudeCode -appearance dark "${FAST[@]}"
# A headless simulator hides the software keyboard; turn that off for this one shot.
KB=(xcrun simctl spawn "$PHONE" defaults write com.apple.keyboard.preferences)
"${KB[@]}" AutomaticMinimizationEnabled -bool false; "${KB[@]}" HardwareKeyboardLastSeen -bool false
shot "$PHONE" ph-type      -echo.demo -echo.demoTwo -echo.draft "Push the countertop crew to the 24th and draft a note to the contractor" -theme claudeCode -appearance dark "${FAST[@]}"
"${KB[@]}" AutomaticMinimizationEnabled -bool true; "${KB[@]}" HardwareKeyboardLastSeen -bool true
fi

if [[ "${ONLY:-}" != phone ]]; then
prepare "$PAD"
shot "$PAD" pad-default-dark -echo.demo -echo.demoLibrary -theme standard -appearance dark "${FAST[@]}" "${CHATS[@]}"
# Pano left half: the Hermes theme, gold on near-black.
shot "$PAD" pad-hermes       -echo.demo -echo.demoLibrary -theme githubDark -appearance dark "${FAST[@]}" "${CHATS[@]}"
shot "$PAD" pad-voice        -echo.demo -echo.voiceView -echo.voiceDemo -voiceOrb darkGlass -theme slate -appearance dark "${FAST[@]}" "${CHATS[@]}"
# Same as the phone work slot: one exchange left most of the detail pane empty.
shot "$PAD" pad-work         -echo.demo -echo.demoTwo -echo.demoLibrary -theme paper -appearance light "${FAST[@]}" "${CHATS[@]}"
shot "$PAD" pad-dark         -echo.demo -echo.demoTwo -echo.demoLibrary -theme claudeCode -appearance dark "${FAST[@]}" "${CHATS[@]}"
# iPad keeps the fast lane here: with the gateway selected the sidebar tries the example host and shows an error.
shot "$PAD" pad-split        -echo.demo -echo.demoLibrary -echo.screen settings -echo.expandAppIcons -theme standard -appearance light "${FAST[@]}" "${CHATS[@]}"
shot "$PAD" pad-phone        -echo.demoPhoneShot -echo.demoLibrary -theme standard -appearance dark "${FAST[@]}" "${CHATS[@]}"
shot "$PAD" pad-gateway      -echo.demo -echo.demoLibrary -echo.demoGateway -echo.screen gateway -theme standard -appearance dark "${FAST[@]}" "${CHATS[@]}"
# 2.3: as on the phone; the detail pane beside the decks shows the packing list and a booking form.
# The backend slot is dark from 2.3, as the rest of the set.
ahead "$PAD" pad-ahead -echo.demoAsks -echo.demoAsksMore -echo.demoLibrary "${FAST[@]}" "${CHATS[@]}"
PADCARDS=(-echo.demoLibrary -theme standard -appearance dark "${FAST[@]}" "${CHATS[@]}")
shot "$PAD" pad-day          -echo.demoAgenda tomorrow "${PADCARDS[@]}"
clock "$PAD"
shot "$PAD" pad-weather      -echo.demoCards weather "${PADCARDS[@]}"
clock "$PAD" 9:41
shot "$PAD" pad-approve      -echo.demoApprovalCard skill "${PADCARDS[@]}"
shot "$PAD" pad-settings     -echo.demo -echo.screen setup "${PADCARDS[@]}"
fi

# 2.0's bot slots (ph-bots, ph-crew, pad-bots, pad-crew) come from PromoVideoUITests.testBotsShots, which
# waits for the round on a group chat's voice screen: see README.

# The car's screens, as CarPlay's own views draw them (scripts/carplay-preview.sh), at the shape
# of a wide dashboard display.
if [[ "${ONLY:-}" != pad ]]; then
REDDE_CARPLAY_STILL=1 scripts/carplay-preview.sh "$RAW/carplay" 770x360 > /dev/null
cp "$RAW/carplay/ask-short-770x360-dark.png" "$RAW/car-ask.png"   # the Ask tab with Short Answers switched on
cp "$RAW/carplay/voice-listening-770x360-dark.png" "$RAW/car-voice.png"
cp "$RAW/carplay/voice-speaking-770x360-dark.png" "$RAW/car-speaking.png"
echo car-ask car-voice car-speaking
fi
