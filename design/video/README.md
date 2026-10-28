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

`make_preview.py fun store` cuts the same takes to 29.2 s for the App Store
(`redde-app-preview-phone-tools.mp4`, made 2026-10-14 for 1.8): the morning, the question
before a change, the timer and its Lock Screen, the widget and its Home Screen, the photo and
the plant, quicker, with the same soundtrack, and no call or text scene, which in a simulator
show only the conversation. The script stops if it comes out over 29.8 s.

## The BOTS! cut

`redde-bots.mp4` (886×1920, about 54 s, with sound; not in git): made 2026-10-20 for a post about
the bots. "BOTS!" drops in a letter at a time in the bots' colours while the Redde bot drops onto
the app icon, squashes it out of its place, and says "Hi! I'm Redde. Meet my crew!" in a speech
bubble; the crew pops up under it and bobs. Then: the chat list (meet the crew), New Bot filled
from the Researcher, Writer and Coder templates (the face picker's shot was taken out at his word), Quill's chat where
Scout and Quill have messaged each other, an @ offering the other bots, the group chat with Scout's
reply coming in, the group's voice screen with Redde, Scout and Quill answering one question in
turn, heard, Scout muted for 8 hours, and Scout's schedules with one opened. The closing page
lists what bots do, with the faces along the bottom, and on the song's last chord the bot drops
onto the icon there too and takes its place. The captions drop in as in the fun cut.

The soundtrack is `fun_music.py`'s `song='bots'`, a funk band at 120 bpm with the drums up front
(swung sixteenths, ghost notes, tom fills into each part, claps and a tambourine later on), a
plucked bass and muted guitar (Karplus-Strong), electric piano and a whistled tune over C–G–Am–F,
laid out on the cut by the cues `make_preview.py` hands it: the keys and a strum over the title,
the drums coming in with a fill into the drop on the first shot, the band and tune over the
features, a light beat (kick, rim, hats) under the keys while the bots talk, a snare roll and
fill back into the tune once the last line is said, and a closing phrase and last chord on the
closing page; a note as each letter lands and a boing as the bot does. `make_preview.py bots chip`
makes the same cut with a chiptune song on the same plan (`redde-bots-chip.mp4`). (Before these:
the fun cut's marimba made into a song, whose busiest part was under the voices, and a bouncy
electro-pop one, too electronic.)

`make_preview.py story` cuts the same takes into the bots App Preview, `redde-app-preview-bots.mp4`
(27 s, made 2026-10-20 for 2.0), calmer and with a small story: Redde's face comes forward and says
"Hi! I'm Redde. Meet my crew!" over "Redde 2.0", the Bots list, the person's question about
Saturday's hike answered by Redde, Scout and Quill in turn on the voice screen (three cuts of
`b7-round`, timed so about 0.4 s of quiet falls between voices across each cross-fade), Scout's
schedules, and the closing page with the bot taking the icon's place on the last chord. Captions
fade in, centred, without emoji; the deep song under it. Upload it by hand as the first iPhone
preview: the store script sends no video.

`make_cool.py` cuts the same takes to the beat instead (`redde-app-preview-bots-cool.mp4`, 29.4 s,
made 2026-10-20): a shot to each 2.5 s bar of the deep song, each sliding in to land on its first
beat over a dark ground the bots' colours drift through, with a big caption (The crew, Build one,
@ each other, Group chats, They talk, Shhh., On schedule) in the story preview's bold and medium,
and the footage held still; the title puts "your agent has a crew." on the beats with the crew
bursting out from Redde's face, and the voice round gives each bot a bar of its line, cut where it
pauses (`lay_voices` takes how much of a line to keep). The closing page has the bot take the
icon's place on the last chord. `make_cool.py long` is the longer cut (`redde-bots-cool-long.mp4`,
54.4 s, over Apple's 30 s, so for anywhere but the store): Redde says hello in a bubble first, most
shots get two bars, a bot passing work on gets one, and each bot says its whole line in the round,
laid where its face says it.

The spoken lines are Kokoro's, in the voices the app gives those bots by default (Redde's
`am_onyx(2)+bm_george(1)`, Scout `bf_v0isabella`, Quill `am_liam`, by `BotVoices.assign`):
`KOKORO_URL=http://<host>:8880 /usr/bin/python3 bot_voices.py` writes `voice-*.wav`. The take
itself is silent, so each line is laid where its bot's turn ends (the app goes to the next bot
when one is heard to the end; the turns were read from the frames), the music dipping under it.

The footage is the demo bots (`-echo.demoBots`) in the Code theme, dark, on the iOS 27 simulator
with the status bar at 9:41. With `B="-echo.demoProjects -echo.demoBots -echo.screen sessions
-conversations.section sessions -theme claudeCode -appearance dark"`:

    ./record.sh b1-list 8 ${=B} -echo.demoMarks -mutes "<>"
    ./record.sh b5-group 15 ${=B} -echo.openGroup -echo.demoDraft
    ./record.sh --test b2-template testBotsTemplate
    ./record.sh --test b3-mention testBotsMention
    ./record.sh --test b4-mute testBotsMuteAndSchedules
    TEST_RUNNER_KOKORO_URL=http://<host>:8880 ./record.sh --test b7-round testBotsVoiceRound

(`-mutes "<>"` because the mute take leaves Scout muted. The round speaks through Kokoro, so its
turns are as long as the lines; xcodebuild didn't exit after it passed and was stopped by hand.) The faces on the two pages are drawn by
the app: `TEST_RUNNER_BOT_FACES=$PWD/design/video/faces xcodebuild test … -only-testing:EchoTests/PromoFacesTests`
writes `faces/face-<name>.png`. Then `cfr-` each take as above and
`/usr/bin/python3 make_preview.py bots` (`bots pages` draws only the two pages).

The simulator writes a frame only when the screen changes, so a take that ends on a still
screen ends early: the Home Screen shot holds its last frame. Cut points were set by looking at
frames, not from the marks alone. xcodebuild sometimes doesn't exit after a passing take, and
the recording runs on until it is stopped (`pkill -f "only-testing:…/<test>"`).

## The next release's cut

`redde-next-app-preview.mp4` (886×1920, 29.4 s, with sound) and `redde-next-reddit.mp4` (49.4 s),
not in git: made 2026-10-28 for the release after 2.2, by `make_next.py` (`long` for the second,
`pages` for stills of the two pages). Cut as the cool cut is (a shot a 2.5 s bar of the deep song,
landing on the downbeat, the footage still). The title: Redde drops in, a tiny phone pops into its
mitten and rings, and it calls out "Hey! It's Redde! Pick up!"; then "Your agent / can call / you."
The shots: an agent's call answered and talked on, a bedtime story asked for on a live call, the
agent working on it with the typing heard (the thinking sound, `Earcons/thinking.wav`), its answer
read in the call's voice as it is written, Settings in each of the 17 languages a beat apiece (and
voice mode in Spanish in the long cut), and the Mac app's icon. The closing page: Redde drops onto
the app icon on the last chord, its phone pops up and it says "Call you later!".

The faces and the phone are drawn by the app: `TEST_RUNNER_BOT_FACES=$PWD/design/video/faces
xcodebuild test … -only-testing:EchoTests/PromoCallingTests` writes `faces/redde-talk-0…3.png`,
`redde-blink.png`, `redde-look.png`, `redde-phone.png` (and `redde-calling.png` to look at), in the
Code theme. The lines: `KOKORO_URL=http://<host>:8880 /usr/bin/python3 next_voices.py` writes
`voice-next-*.wav` (Redde's own voice; the person's is af_heart; the people are made up).

The footage is voice mode posed (DEBUG flags in `VoiceView`, all in `DevHooks`' list), on an iOS 27
simulator of its own, Code theme, dark, status bar at 9:41, Redde reinstalled before each so no
conversation is left over. With `C="-echo.voiceView -echo.voiceDemoCall -theme claudeCode -appearance dark"`:

    ./record.sh n1-call 12 ${=C} -echo.voiceDemo -echo.voiceDemoPhase speaking -echo.voiceDemoSaid "Hi, it's Redde! Your package just came!" -echo.voiceDemoReveal 0.36
    ./record.sh n2-thanks 11 ${=C} -echo.voiceDemo "Thanks! Can you remind me to bring it in at six?" -echo.voiceDemoReveal 0.23
    ./record.sh n2b-done 11 ${=C} -echo.voiceDemo -echo.voiceDemoPhase speaking -echo.voiceDemoSaid "Done! I'll remind you at six." -echo.voiceDemoReveal 0.36
    ./record.sh n3-story 21 ${=C} -echo.voiceDemo "Tell Milo a bedtime story about our dog, Pickles." -echo.voiceDemoPhase follow -echo.voiceDemoReveal 0.32 -echo.demoCall story 4.5

(`follow`: listening while the words come in, thinking once the question is there, speaking from
the answer's first word; `-echo.demoCall story` plays the exchange.) The language stills are
`xcrun simctl io <sim> screenshot lang-<code>.png` of a plain launch with `-echo.demo -echo.screen
settings -AppleLanguages "(<code>)" -AppleLocale <locale>` (seven seconds after the launch), and
`lang-es-voice.png` voice mode in Spanish (`-echo.voiceView -echo.voiceDemo "Recuérdame sacar la
basura a las ocho."`). `cfr-` each take as above. Cut points were set from frames: the screen comes
up five to seven seconds into a take, and the voices start where their first word shows.

The Mac shot is the Mac app's icon because the Mac was locked when this was made: a locked Mac
opens no windows to capture. With it unlocked, a window capture of the Mac app (built with another
bundle id, unsigned, launched with `CFFIXED_USER_HOME` pointing at a folder of its own, so none of
the real app's data is touched) could take its place as a `take`.
