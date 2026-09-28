# App Store preview video

`redde-app-preview-iphone.mp4` (886×1920, about 26 s) and `redde-app-preview-ipad.mp4`
(1200×1600, about 28 s), not in git: rebuild them. 30 fps, H.264, silent stereo AAC. Upload in
App Store Connect → the version → App Previews (6.9" iPhone, 13" iPad).

**Rebuild** (iPhone 17 Pro Max simulator, Debug build installed, working dir = this folder):
1. `./record.sh c1-stream 10 -echo.demoStream -theme claudeCode -appearance dark`
2. `./record.sh c2-voice 6 -echo.demo -echo.voiceView -echo.voiceDemo -voiceOrb waveform -theme slate -appearance dark`
3. `./record.sh --test c3-rich testRichAnswers`, `--test c4-kanban testConversationsAndKanban`,
   `--test c5-yours testMakeItYours` (UI tests in `EchoUITests/PromoVideoUITests.swift`, run only
   with `TEST_RUNNER_PROMO_VIDEO=1`)
4. `./record.sh c4b-kanban 6 -echo.demo -echo.demoKanban -echo.screen sessions -echo.section kanban -theme claudeCode -appearance dark`
5. Convert each to constant frame rate (`ffmpeg -i cN.mov -vf fps=30 cfr-cN.mov`), check the cut
   points in `SHOTS` against the takes, then `/usr/bin/python3 make_preview.py`.

Uninstall the app on the simulator first, so the conversation list holds only the demo chats.

**iPad:** the same with `SIM=<iPad Pro 13-inch UDID>` and `ipad-` names: `ipad-c1-stream` (add
`-echo.demoLibrary`; launch once first, as a fresh install's first launch shows a key prompt),
`ipad-c2-voice`, `--test ipad-c3-rich testRichAnswers`, `ipad-c4-kanban` (plain launch with
`-echo.demo -echo.demoLibrary -echo.demoKanban -echo.section kanban`; the sidebar shows it),
`--test ipad-c5-yours testMakeItYours`; then `/usr/bin/python3 make_preview.py ipad`.
