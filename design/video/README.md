# App Store preview video

`redde-app-preview-iphone.mp4` (886×1920, about 29 s) and `redde-app-preview-ipad.mp4`
(1200×1600, about 29 s), not in git: rebuild them. 30 fps, H.264, silent stereo AAC. Upload in
App Store Connect → the version → App Previews (6.9" iPhone, 13" iPad). Apple takes 15 to 30
seconds; `make_preview.py` stops if the cut runs longer.

The cut: a title page; a new conversation, blank, on the start screen; the question sent from
it and answered live; then voice, rich answers, the workspace, setup by QR code, themes and icons,
each a captioned shot; then a closing page that lists the feature set. The two pages are drawn
by `make_preview.py`, not recorded (`make_preview.py pages` writes them as stills to look at).

**Rebuild** (iPhone 18 Pro Max simulator, Debug build and UI tests built into `DerivedData`,
working dir = this folder):
1. `./record.sh c1-stream 13 -echo.demoStream 2.8 -echo.demoLibrary -theme claudeCode -appearance dark`
   (the number: the start screen holds that many seconds before the question is sent; this one
   take is the cut's second and third shots)
2. `./record.sh c2-voice 7 -echo.demo -echo.voiceView -echo.voiceDemo -voiceOrb darkGlass -theme slate -appearance dark`
3. `./record.sh --test c3-rich testRichAnswers`, `--test c4-kanban testConversationsAndKanban`,
   `--test c5-yours testMakeItYours`, `--test c7-code testSetUpByCode` (UI tests in
   `EchoUITests/PromoVideoUITests.swift`, run only with `TEST_RUNNER_PROMO_VIDEO=1`)
4. `./record.sh c4b-kanban 6 -echo.demo -echo.demoKanban -echo.screen sessions -echo.section kanban -theme claudeCode -appearance dark`
5. Convert each to constant frame rate (`ffmpeg -i cN.mov -vf fps=30 cfr-cN.mov`), check the cut
   points in `SHOTS` against the takes, then `/usr/bin/python3 make_preview.py`.

Uninstall the app on the simulator first, so the conversation list holds only the demo chats.
A take starts with the Home Screen and the launch, three to five seconds of it; a recording also
ends at the last frame that changed, so a still screen is held with the fifth value in `SHOTS`.

On iOS 27 the tap on Kanban in `testConversationsAndKanban` doesn't land after the swipe, so the
cut uses that take for the swipe and `c4b-kanban` for the board.

**iPad:** the same with `SIM=<iPad Pro 13-inch UDID>` and `ipad-` names: `ipad-c1-stream` (add
`-conversations.section sessions`; launch once first, as a fresh install's first launch shows a
key prompt), `ipad-c2-voice`, `--test ipad-c3-rich testRichAnswers`, `ipad-c4-kanban` (plain
launch with `-echo.demo -echo.demoLibrary -echo.demoKanban -echo.section kanban`; the sidebar
shows it), `--test ipad-c5-yours testMakeItYours`, `--test ipad-c7-code testSetUpByCode`; then
`/usr/bin/python3 make_preview.py ipad`. The 1.6 cut was recorded on iPadOS 27. A plain launch
on the iPad can take five seconds or more to show the app: give `ipad-c2-voice` 14 seconds, and
hold the board in `ipad-c4-kanban` with the fifth value in `SHOTS` (its take ends as soon as the
board is up).

## The Phone tools cut

`redde-phone-tools.mp4` (886×1920, about 35 s, the same format, with no length limit since it is
for a post and not for the App Store; not in git). A title page; the agent reading tomorrow's
calendar; Phone tools' own question before the reminder is added, and the yes; a photo found
by what it shows; a call; a message; Settings → Phone tools with an area being set; a closing
page that lists the areas. (The first one, made 2026-10-13 from 1.8's five areas, was 29 s
without the call and the message.)

The footage is `-echo.demoPhone` (`Conversation.streamPhoneDemo`): played exchanges in which
nothing on the simulator is read or changed. The question before the reminder is the real one
(`DeviceToolsService` with stand-ins behind it), so the take waits for the test to tap Allow.
The call and the message (`-echo.demoPhone reach`) are only spoken of in a simulator, which has
no phone for iOS to ask about and no Messages to open; on an iPhone the same flag brings up
iOS's "Call…?" and the Messages sheet, with numbers that are nobody's, and a recording made
there would show them.

1. `xcrun simctl uninstall <simulator> com.goosehouse.echo`, then
   `./record.sh --test c8-phone testPhoneTools` and `./record.sh --test c10-reach testPhoneToolsReach`
2. `xcrun simctl privacy <simulator> grant contacts com.goosehouse.echo` (the Settings take picks
   "Allow reading" for Contacts, which asks iOS for them), then
   `./record.sh --test c9-phone-settings testPhoneToolsSettings`
3. `ffmpeg -i c8-phone.mov -vf fps=30 cfr-c8-phone.mov`, the same for the other two, then
   `/usr/bin/python3 make_preview.py phone` (`phone pages` draws only the two pages).

Each take prints its `t0` and the test's marks; a mark less `t0` is its second in the take. The
cut in `SHOTS` was set from these: in `c8-phone` the question arrives a second and a half after
`start`, the alert is up at `asked` and tapped at `allowed`, and the photo is in the reply a
moment before `end` less three seconds; in `c10-reach` the call's reply is written at `called`
and the message's at `sent`; in the Settings take the choice lands about two seconds before
`end`.

## The fun cut

`redde-phone-fun.mp4` (886×1920, about 55 s, with sound; not in git): made 2026-10-14 for the
release that carries the whole of Phone tools. A day with the agent, one scene per area: the
calendar in the morning and a reminder asked about, a pasta timer and then the Lock Screen
counting it down, a shopping list saved to Files and then the widget showing it on the Home
Screen, the bowling scoreboard, a houseplant shown in voice mode with the camera on and the
answer, a call and a text. Captions drop in with an emoji, chat runs 15 to 30 percent fast, and
the closing page lists every area. The soundtrack is drawn by `fun_music.py` (marimba, bass,
light drums, a "bloop" as each caption lands), so there is nothing to license.

The footage is `-echo.demoFun <scene>` (`Conversation.streamFunDemo`); the timer and the widget
are real (AlarmKit and the App Group), the rest is played. Two simulators, because of what
each can do:

- The timer and the widget on an iOS 26.3 simulator made for it (`xcrun simctl create`): the
  iOS 27.0 simulator refuses AlarmKit. A new 26.3 simulator draws emoji as boxes, so those
  two scenes' replies have none. Open Redde on it once, wait a minute (the widget gallery is
  slow to find a new app's widgets), then
  `TEST_RUNNER_PROMO_VIDEO=1 xcodebuild … -only-testing:EchoUITests/PromoVideoUITests/testFunReady`:
  it allows Alarms, adds the widget, files the test runner's icon into a folder and clears the
  Lock Screen. No status bar override for the timer take: with one (even just the time) the
  Lock Screen showed "Sat Jan 1" and no countdown.
- The rest on the usual iOS 27 simulator.

Then `SIM=<udid> ./record.sh --test f1-morning testFunMorning` and so on (`f2-timer`, `f3-widget`,
`f4-photo`, `f5-look`, `f6-reach`), `ffmpeg -i <take>.mov -vf fps=30 cfr-<take>.mov` for each, and
`/usr/bin/python3 make_preview.py fun` (`fun pages` draws only the two pages).

The simulator writes a frame only when the screen changes, so a take that ends on a still
screen ends early: the Home Screen shot holds its last frame. Cut points were set by looking at
frames, not from the marks alone. xcodebuild sometimes doesn't exit after a passing take, and
the recording runs on until it is stopped (`pkill -f "only-testing:…/<test>"`).
