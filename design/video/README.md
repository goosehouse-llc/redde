# App Store preview video

`redde-app-preview-iphone.mp4` (886×1920, about 29 s) and `redde-app-preview-ipad.mp4`
(1200×1600, about 29 s), not in git: rebuild them. 30 fps, H.264, silent stereo AAC. Upload in
App Store Connect → the version → App Previews (6.9" iPhone, 13" iPad). Apple takes 15 to 30
seconds; `make_preview.py` stops if the cut runs longer.

The cut: a title page, then each feature as a captioned shot (the agent answering live, voice,
rich answers, the workspace, the start screen, setup by QR code, themes and icons), then a closing
page that lists the feature set. The two pages are drawn by `make_preview.py`, not recorded
(`make_preview.py pages` writes them as stills to look at).

**Rebuild** (iPhone 18 Pro Max simulator, Debug build and UI tests built into `DerivedData`,
working dir = this folder):
1. `./record.sh c1-stream 11 -echo.demoStream -theme claudeCode -appearance dark`
2. `./record.sh c2-voice 7 -echo.demo -echo.voiceView -echo.voiceDemo -voiceOrb darkGlass -theme slate -appearance dark`
3. `./record.sh --test c3-rich testRichAnswers`, `--test c4-kanban testConversationsAndKanban`,
   `--test c5-yours testMakeItYours`, `--test c6-start testAPlaceToStart`,
   `--test c7-code testSetUpByCode` (UI tests in `EchoUITests/PromoVideoUITests.swift`, run only
   with `TEST_RUNNER_PROMO_VIDEO=1`)
4. `./record.sh c4b-kanban 6 -echo.demo -echo.demoKanban -echo.screen sessions -echo.section kanban -theme claudeCode -appearance dark`
5. Convert each to constant frame rate (`ffmpeg -i cN.mov -vf fps=30 cfr-cN.mov`), check the cut
   points in `SHOTS` against the takes, then `/usr/bin/python3 make_preview.py`.

Uninstall the app on the simulator first, so the conversation list holds only the demo chats.
A take starts with the Home Screen and the launch, three to five seconds of it; a recording also
ends at the last frame that changed, so a still screen is held with the fifth value in `SHOTS`.

On iOS 27 the tap on Kanban in `testConversationsAndKanban` doesn't land after the swipe, so the
cut uses that take for the swipe and `c4b-kanban` for the board.

**iPad:** the same with `SIM=<iPad Pro 13-inch UDID>` and `ipad-` names: `ipad-c1-stream` (add
`-echo.demoLibrary -conversations.section sessions`; launch once first, as a fresh install's
first launch shows a key prompt), `ipad-c2-voice`, `--test ipad-c3-rich testRichAnswers`,
`ipad-c4-kanban` (plain launch with `-echo.demo -echo.demoLibrary -echo.demoKanban -echo.section
kanban`; the sidebar shows it), `--test ipad-c5-yours testMakeItYours`, `--test ipad-c6-start
testAPlaceToStart`, `--test ipad-c7-code testSetUpByCode`; then `/usr/bin/python3 make_preview.py
ipad`. The 1.6 cut was recorded on iPadOS 26.3, as the screenshots were (see
`../screenshots/README.md`: in that build iPadOS 27 squeezed the sidebar's title).
