# App Store preview video

## App Store cuts: full frame, overlays only (standing rule)

App Review turned down 2.2's App Preview on 2026-10-29 (Guideline 2.3.4): "The app preview includes
framing around the video screen capture of the app. App previews should allow users to see what
the app does and how it will appear on their device when the preview is played in full screen.
Revise the app preview to only use video screen captures of the app that may include narration and
video or textual overlays." So every cut meant for App Store Connect (the `*app-preview*` files):

- The screen capture fills the whole frame, edge to edge, at the device's own aspect: 886×1920 for
  the 6.9" iPhone (a 1320×2868 capture scaled to 886 wide, 2 or 3 rows cropped top and bottom),
  1200×1600 for the 13" iPad (its 2064×2752 capture, 3:4, scaled).
- No ground, device frame, rounded inset, glow, colour bars beside the footage, or drawn pages.
- Captions, the person's quoted words and the titles are text laid over the footage, on a dark
  scrim fading up from the foot of the screen (the app shows through it); the title and the
  closing are app footage with their words over it. No drawn faces or props (the Redde bot, its
  tiny phone): its lines stay as narration, heard. Music and voices are fine.
- At most 30 s (the scripts stop at 29.8).

`store_cut.py` holds the pieces (`band`, `shot`, `page`, `words_over`, `assemble`); `make_day.py`
and `make_next.py` cut their App Store versions this way by default (`framed` draws the old framed
look, to `…-app-preview-framed.mp4`, only to compare), and `make_preview.py [ipad] fullframe` the
general previews. The Reddit cuts (`long`) may keep the framed style.

`redde-app-preview-iphone.mp4` (886×1920, about 29 s) and `redde-app-preview-ipad.mp4`
(1200×1600, about 29 s), not in git: rebuild them. These two are framed (footage inset on a navy
ground) and no longer pass App Review; their full-frame versions, made 2026-10-29 from the same
takes, are `redde-app-preview-iphone-fullframe.mp4` (29.6 s) and `redde-app-preview-ipad-fullframe.mp4`
(29.1 s), by `/usr/bin/python3 make_preview.py fullframe` and `make_preview.py ipad fullframe`: the same
shots and cross-fades, each take filling the frame with its caption (gold bar, title, line) over its
foot, "Redde / for Hermes / Talk, chat and run your agent" over the first shot's start screen, held,
and the feature list over the last shot's last frame, held; silent, as before. 30 fps, H.264, silent stereo AAC. Upload in
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

`redde-next-app-preview.mp4` (886×1920, 29.4 s, with sound) and `redde-next-reddit.mp4` (49.4 s;
`redde-next-reddit-small.mp4`, 664×1440, under 5 MB, for posting), not in git: made 2026-10-28 for
the release after 2.2, by `make_next.py` (`long` for the second, `pages` for stills of the two
pages). Since 2026-10-29 the App Store cut is full frame (see "App Store cuts"): the title is Redde
on a call saying "Hey! It's Redde! Pick up!" (`nt-hey`) with "Your agent / can call / you." over it,
then the call, "Thanks!…", "Done!…", the story in two bars, the languages, voice mode in Spanish in
the Mac's place (the Mac shot is a drawn icon, not footage), and the closing over Redde saying
"Call you later!" (`nt-bye`). Those two takes:

    ./record.sh nt-hey 12 ${=C} -echo.voiceDemo -echo.voiceDemoPhase speaking -echo.voiceDemoSaid "Hey! It's Redde! Pick up!" -echo.voiceDemoReveal 0.3
    ./record.sh nt-bye 12 ${=C} -echo.voiceDemo -echo.voiceDemoPhase speaking -echo.voiceDemoSaid "Call you later!" -echo.voiceDemoReveal 0.3

(the words are up by 6.4 s into each). The framed description below is the Reddit cut's. Cut as the cool cut is (a shot a 2.5 s bar of the deep song,
landing on the downbeat, the footage still). The title: Redde drops in, a tiny phone pops into its
mitten and rings, and it calls out "Hey! It's Redde! Pick up!"; then "Your agent / can call / you."
The shots: an agent's call answered and talked on, a bedtime story asked for on a live call, the
agent working on it with the typing heard (the thinking sound, `Earcons/thinking.wav`), its answer
read in the call's voice as it is written, Settings in each of the 17 languages a beat apiece (and
voice mode in Spanish in the long cut), and the Mac app's icon. The closing page: Redde drops onto
the app icon on the last chord, its phone pops up and it says "Call you later!".

What the person says is in the captions, in “quotes” and SF's medium italic, white, in place of the
line under the big words (made 2026-10-29, at his word: "When the 'user' is prompting in the video,
put the request in quotes and italics to clearly identify it's a user talking"): on voice mode's
screen the person's words and the agent's look the same. A caption is (big words, line) or (big
words, line, what the person says); `make_cool.caption` draws the third on one line or two, evened
out. Here: “Thanks! Can you remind me to bring it in at six?” on the call, and “Tell Milo a bedtime
story about our dog, Pickles.” (the App Store cut's story shot is two of a bar each, the first with
the request and the second with the line; in the long cut, on "On a live call"). Narration and
feature captions stay upright and unquoted. Shots with the same big words don't slide in again;
the line, or the person's words, cross-fades with the shot.

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

## A day with Redde

`redde-day-app-preview.mp4` (886×1920, 29.4 s, with sound; full frame since 2026-10-29, see "App Store
cuts") and `redde-day-reddit.mp4` (76.9 s; a
copy for posting under 5 MB, `redde-day-reddit-small.mp4`, 664×1440), not in git: made 2026-10-28 for
the release with briefings, ideas, @tags, triggers, watches, routines and the interactive cards, by
`make_day.py` (`long` for the Reddit cut, `pages` for stills of the title, ring and closing pages),
and redone 2026-10-29 for round 3 (the Briefings deck, the Week Ahead as a calendar, a heads-up's
event card, maps for addresses) and with the person's words in “quotes” and italics. Cut as the
next release's is (a shot a 2.5 s bar of the deep song, landing on the downbeat, the footage still,
`render_deep`), told as one day: each caption has the scene's time of day beside its colour bar (a
sun or a moon), and the status bar in the footage says the same. The title: a sun comes up, Redde
drops in, its tiny phone buzzes and it calls "Rise and shine! It's Redde!", then "A day / with /
Redde.".

The App Store cut, full frame: the chat list at 7:00 before the heads-up (`d1-morning` 20.6–22.95,
held) with "Rise and shine! / It's Redde." and then "A day / with / Redde." over it; the starred
shots below, each with its caption over the foot of the screen; and the closing ("Redde" and three
lines) over Sol saying "See you tomorrow!" on the call (`d12-bye`, at 22:41: `./record.sh d12-bye 12
${=C} -echo.voiceDemo -echo.voiceDemoPhase speaking -echo.voiceDemoSaid "See you tomorrow!"
-echo.voiceDemoReveal 0.3`). Redde's peeks are heard only.

The shots, the long cut's (the App Store cut's marked *):
- 7:00 AM Heads-ups*: the Week Ahead's card on the Briefings deck, then the dentist's heads-up
  arriving as a banner and on top of the deck with "7:30 AM · Leave by 7:10 AM" and the address
  (Redde pops up in the corner to say it).
- 7:01 AM Where and when*: the heads-up opened: its event card (THU 29 badge, 7:30 AM · in 30 min,
  the address, Leave by 7:10 AM, Open in Calendar) and the map of the address with Directions.
- 7:02 AM Your week*: the Week Ahead on top of the deck, its strip of days, then opened as a calendar.
- 7:05 AM Ideas for you*: the bagpipes swiped away (the long cut: the person's “Bagpipes? Not
  now.”), the vet swiped in; 7:06 AM Do it (long): Sol booking it.
- 12:30 PM @ any bot (long): “@home is the garage shut?” in a chat with Sol, answered under Home's face.
- 6:05 PM Triggers (long): Home's answer to the arrive-home automation as Redde's notification.
- 6:30 PM Pick one*: “Where should we go for dinner?” answered with a choice card, Lupa Trattoria
  tapped (the others fade, Redde peeks in: "Ooh, pasta!") and Sol booking it; 6:31 PM Maps for
  addresses (long): the booking names Lupa's address, and a map with Directions comes under it.
- 8:00 PM Checklists*: “Make me a packing list for the cabin”, its last three things ticked
  ("Everything's done. Nice! 🎉").
- 9:00 PM Evening wrap-up (long), on top of the deck and opened; 9:05 Routines, Agent activity,
  Plugin updates (long).
- 10:00 PM Watches (long): “The garage door. If it's still open after 10 pm, that's a change.”,
  Home watching, a change handed to Sol.
- 10:40 PM It calls you: the tiny phone ringing ("Sol is calling…", long), Sol's call* (in the App
  Store cut, two bars with "Home saw the garage open. Sol rang.", for the watch it leaves out), the
  person's “Oh! Yes, please.” (long), "Done! It's shut. Sleep tight!" (long).

The long cut's closing page: night, Redde drops onto the icon, says "See you tomorrow!", tucks its phone away and
nods off, over "Heads-ups, briefings and ideas. / Your week, maps, cards to tap. / (long: @ any bot.
Triggers. Routines.) / Watchers that call you.". (The first version, 59.4 s, had the Triggers page
as a shot of its own; `testDayTriggers` and `d4-triggers` are kept, unused. The 2026-10-28 cut had
the old Briefings list, no week, event card or maps, and @ any bot and Watches in the App Store cut.)
Where the person talks or types, the caption carries their words in quotes and italics in place of
its line (see "The next release's cut").

The lines: `KOKORO_URL=http://<host>:8880 /usr/bin/python3 day_voices.py` writes `voice-day-*.wav`
(Redde's and Sol's in Redde's own voice, the person's af_heart; nobody real is named). The 10-29
redo said nothing new, so the files were kept. The faces and the tiny phone are the next release's
(`faces/`, PromoCallingTests).

The footage is `-echo.demoDay <scene>` (`Echo/Services/DemoDay.swift`, DEBUG only) with
`-echo.demoProjects -echo.demoBots -displayName Sol`: the agents Sol, Home and Coder, an ordinary
day's chats, canned answers to a chat and an @tag (`DemoDayTransport`; dinner comes with a choice card and the
packing list with a checklist card, each shown by a `redde_show` call as a live turn's are), sample Agent Activity and
Plugin Updates (whose updates "go"), a new watch's agents and a routine's schedule as on the
Dashboard. The heads-up carries its event's start, its place and when to leave, as the plugin (1.9)
and `LeaveTime` give them; the Week Ahead is written in its job's layout, dated from the day it is
shown; the addresses are made-up places on real streets of Burlington, VT, so the maps have
somewhere to put the pin (`DemoDay.dentistAddress`, `lupaAddress`). The event card counts down from
the story's clock, 7:00 (`DemoDay.storyNow`, DEBUG), as the simulator's own clock is the Mac's. The
vet is booked "tomorrow" so no weekday disagrees with the badge's.

The takes are UI tests (`PromoVideoUITests`, `testDay…`), on an iOS 27 iPhone 18 Pro Max simulator
made for them (10-29: "Redde day video 10-29", 395C295F-FB35-4596-9100-4CE66EE9E725), Redde
reinstalled before each (`xcrun simctl uninstall $SIM com.goosehouse.echo`), the status bar set to
the scene's time by `day_status.sh HH:MM` (full bars, charging; iOS 27 wants an ISO time with
fractions of a second), Code theme, dark. Build the tests into a DerivedData of their own when
another build may be running in `DerivedData` (`DD=DerivedData-day`, which `record.sh` reads):

    xcodebuild -project Echo.xcodeproj -scheme EchoUITests -destination "id=$SIM" -derivedDataPath DerivedData-day build-for-testing
    export SIM=<udid> DD=DerivedData-day
    ./day_status.sh 07:00; ./record.sh --test d1-morning testDayMorning    # asks to notify: the test taps Allow
    ./day_status.sh 07:02; ./record.sh --test d11-week testDayWeek
    ./day_status.sh 07:05; ./record.sh --test d2-ideas testDayIdeas
    ./day_status.sh 12:30; ./record.sh --test d3-aside testDayAside
    ./day_status.sh 18:05; ./record.sh --test d4-triggers testDayTriggers
    ./day_status.sh 18:05; ./record.sh --test d4b-home testDayHome        # (run testDayTidy once first)
    ./day_status.sh 18:30; ./record.sh --test d9-dinner testDayDinner
    ./day_status.sh 20:00; ./record.sh --test d10-packing testDayPacking
    ./day_status.sh 21:00; ./record.sh --test d5-evening testDayEvening
    ./day_status.sh 21:05; ./record.sh --test d6-routine testDayRoutine
    ./day_status.sh 21:05; ./record.sh --test d6b-activity testDayActivity
    ./day_status.sh 21:05; ./record.sh --test d6c-plugins testDayPlugins
    ./day_status.sh 22:00; ./record.sh --test d7-watch testDayWatch

On 10-29 `d1-morning`, `d11-week`, `d2-ideas`, `d9-dinner` and `d5-evening` were taken again (the
chat list's Briefings became a deck, the heads-up an event card, and dinner's answer a map); the
rest are the 10-28 takes, whose screens didn't change. `testDayTidy` takes the test runner's icon off the Home Screen (Remove App → Remove from Home
Screen), so the arrive-home take shows only the simulator's own apps and Redde. The call is voice
mode posed as last time; with `C="-echo.voiceView -echo.voiceDemoCall -theme claudeCode -appearance
dark -displayName Sol -echo.demoProjects -echo.demoBots -echo.demoDay call"`, at 22:40:

    ./record.sh d8-call 12 ${=C} -echo.voiceDemo -echo.voiceDemoPhase speaking -echo.voiceDemoSaid "Hi, it's Sol! Home says the garage door is still open. Want me to close it?" -echo.voiceDemoReveal 0.3
    ./record.sh d8b-yes 10 ${=C} -echo.voiceDemo "Oh! Yes, please." -echo.voiceDemoReveal 0.25
    ./record.sh d8c-done 10 ${=C} -echo.voiceDemo -echo.voiceDemoPhase speaking -echo.voiceDemoSaid "Done! It's shut. Sleep tight!" -echo.voiceDemoReveal 0.32

Then `ffmpeg -i <take>.mov -vf fps=30 cfr-<take>.mov` for each and `/usr/bin/python3 make_day.py`
(and `long`). The small copy: `ffmpeg -i redde-day-reddit.mp4 -vf scale=664:1440 -c:v libx264 -b:v
420k -pass 1 …` then `-pass 2` with `-c:a aac -b:a 64k` (two passes at a set rate, so it lands under
5 MB). A UI test's mark less its `t0`, plus 1.2 s (`record.sh` starts recording that long
before), is its second in the take; the cut points in `SHOTS` were set from those and from frames.
In the 10-29 takes: the heads-up lands 23.8 s into `d1-morning` and its sheet opens at 28.3 (the
banner over it until about 31.3); the week's card is up at 28.3 in `d11-week` and its calendar at
31; in `d9-dinner` the card is up at 25.2, Lupa tapped at 28.6, the map under the answer at 33.3
and in full view at 34.3; in `d2-ideas` the bagpipes go at 21.4 and the vet at 27. The voice screen
is up about 5.7 s into each call take. Shortcuts itself isn't filmed (an
automation can't be run convincingly on a simulator): Triggers from Your iPhone shows the recipe,
and the notification is the one `BotTrigger.post` makes, posted by the demo at the time the
automation would. Not filmed either: the Up Next Lock Screen widget (a Lock Screen widget can't be
added and shown convincingly on the simulator from a test) and Earlier Chats (it doesn't fit the
day's story).

## A day with Redde, for 2.3

`../redde-day23-app-preview-iphone.mp4` (886×1920, 29.4 s, full frame), `../redde-day23-app-preview-ipad.mp4`
(1200×1600, 29.4 s, full frame) and `../redde-day23-reddit.mp4` (886×1920, 71.9 s, framed; a copy for
posting under 5 MB, `../redde-day23-reddit-small.mp4`, 664×1440, two passes at 430k), not in git: made
2026-10-30 for 2.3 by `make_day23.py` (`ipad`, `long`; `pages` for stills of the long cut's title and
closing), and redone that evening at his word ("add in traffic recheck, watches and followups, and if
possible free spot but don't cram it in"). The same day retold with the answer cards redesigned that
day and the proactive features, cut as the day video before it (a shot a 2.5 s bar of the deep song,
landing on the downbeat, the time of day by each caption, the person's words in “quotes” and italics).
make_day.py's pages, shots and soundtrack are used as they are (its module's globals set to this cut's),
so the long cut looks like the 10-29 one; the App Store cuts follow the standing rule above (`store_cut.py`).

The day (the long cut's shots; the App Store cuts' marked *). To give the traffic re-check and the watch
a beat each, the App Store cuts left out the coffee and the Leave-By Alert (the re-check's notification
says when to leave); the free spot is in the long cut only.
- 7:00 AM Morning ideas*: the bagpipes swiped away (Not Now), the vet card; (long) the vet swiped
  right, and Sol booking it ("Swipe right, and Sol does it.").
- 7:50 AM Your day* (two bars): “What's my day look like?”, today as a timeline (the walk over and
  dimmed, the now line, "Free for 2½ hours"), then the dentist tapped open in place.
- 7:51 AM Free time (long, two bars): the free stretch tapped, Apple's new-event editor at 10–11 AM,
  "Walk by the lake" typed (the editor's slow first showing, a dark screen, left out with `fix`).
- 10:15 AM Near you (long): “Good coffee near me?”, places with walks from where the phone is.
- 10:40 AM Watches & follow-ups (long, two bars): “Let me know when the bike part ships. I'll call the
  plumber tomorrow.”, Sol: watching the order every hour, and back about the plumber tomorrow at 9.
- 11:30 AM Plain-English approvals (long): Coder's `rm -rf` as "Deletes ~/builds/2025-* …" in red.
- 12:10 PM The forecast*: “Will it rain this afternoon?”, "Storms likely 2 – 5 PM · 80% at 3 PM".
- 1:30 PM Heads-ups*: the dentist's heads-up (Leave by 2:05) on the deck and as a banner (Redde:
  "Dentist at two thirty! …"); 1:31 Where and when (long): its event card and map.
- 1:45 PM Traffic, checked again*: "Dentist: traffic is heavier · Leave by 1:55 PM · 35 min by car",
  time-sensitive, as the notification extension shows it (`LeaveCheck.content(.heavier, …)`); Redde:
  "Traffic's heavier! Leave at one fifty-five."
- 1:50 PM Time to leave (long): the Leave-By Alert at the moved time, held, with Open in Maps.
- 3:35 PM Review, then send*: the email to Ana; (long) Send, and "Sent".
- 4:20 PM Watches & follow-ups*: over Watches & Follow-ups, the watch's note arrives ("The bike part
  order · It shipped! 📦 Arriving Thursday by 8 PM.") and its row says so; the plumber's follow-up
  below it (Redde: "Your bike part shipped!").
- 8:00 PM Checklists (long): the cabin's list ticked to 8 of 8.
- 9:00 PM Evening wrap-up*: on the deck, then opened; the closing ("Redde / Ideas, heads-ups, traffic
  re-checked. / Your day and the weather, as cards. / Watches that come back with news.") over it, as
  "See you tomorrow!" is heard. The App Store cuts open on the chat list at 7:00 with "A day / with /
  Redde." over it ("Rise and shine! It's Redde!" heard); the long cut has the drawn title and closing.

The lines: `KOKORO_URL=http://<host>:8880 /usr/bin/python3 day_voices.py` makes the ones not made yet
(`headsup2`, `leave`, `coffee`, `sent`, then `traffic`, `leave2`, `shipped`; `all` makes every line again).

The footage is `-echo.demoDay <scene>` (`DemoDay.swift`): `today` (an agenda card of today), `coffee`
(places, the phone said to be by City Hall Park), `watchask` (the watch and follow-up asked for, answered),
`approval` (Coder's chat with an approval waiting; answered, Coder carries on), `rain`, `afternoon` (the
heads-up, for a 2:30 dentist), `traffic` (the re-check's notification), `leave` (the Leave-By Alert, by
`LeaveTime.content`, at 1:55 after the re-check), `email` (a review card; Send gets "Sent"), `shipped`
(the watch's note, as the plugin sends one, over `-echo.screen watches`: Watches & Follow-ups lists the
demo's jobs, `DemoDay.watchJobs`, and the note's row is kept a moment after the banner shows), `packing`
and `evening`. `DemoDay.storyNow` gives each scene its time (the calendar card's now line and dimming,
the weather card's "Now", the greeting, the event card's countdown; `-echo.demoDayClock HH:MM` for any
scene); the phone's own weather lookup is skipped in the demo, so the forecast stays as written.

The takes are UI tests (`PromoVideoUITests`), each by `take23.sh <HH:MM> <name> <test>`, which reinstalls
Redde, sets the status bar to the scene's time on 2026-10-30 (`day_status.sh HH:MM 2026-10-30`: as UTC and
set again on its own, or the iPad's status bar names the wrong weekday) and records. Built into
`DerivedData-video`:

    xcodebuild -project Echo.xcodeproj -scheme EchoUITests -destination "id=$SIM" -derivedDataPath DerivedData-video build-for-testing
    ./take23.sh 07:00 e1-ideas testDayIdeas;       ./take23.sh 07:50 e2-today testDayToday
    ./take23.sh 07:50 e2b-add testDayAddEvent;     ./take23.sh 10:15 e3-coffee testDayCoffee
    ./take23.sh 10:40 e3b-watchask testDayWatchAsk; ./take23.sh 11:30 e5-approval testDayApproval
    ./take23.sh 12:10 e4-rain testDayRain;         ./take23.sh 13:30 e6-afternoon testDayAfternoon
    ./take23.sh 13:45 e7a-traffic testDayTraffic
    TEST_RUNNER_PROMO_EXPAND=1 ./take23.sh 13:50 e7-leave testDayLeave       # (holds the banner open)
    ./take23.sh 15:35 e8-email testDayEmail;       ./take23.sh 16:20 e11-shipped testDayShipped
    ./take23.sh 20:00 e9-packing testDayPacking;   ./take23.sh 21:00 e10-evening testDayEvening

on the iPhone simulator "Redde day video 10-29" (395C295F-FB35-4596-9100-4CE66EE9E725, the default), and
the App Store cut's takes again on the 13" iPad (`SIM=21E37828-1093-41DC-8DCB-D375ADABFECB`, iOS 27.0) as
`ipad-e…` (e1, e2, e4, e6, e7a, e8, e10, e11; its first launch after an install takes a minute or more).
`testDayAddEvent` taps Apple's editor's Add by place (it isn't found by name); the take is cut before it.
Then `ffmpeg -i <take>.mov -vf fps=30 -c:v libx264 -crf 12 -preset fast -pix_fmt yuv420p cfr-<take>.mov`
for each, and `/usr/bin/python3 make_day23.py` (and `ipad`, `long`). The cut points are in `SHOTS` (the
iPad's in `day23_ipad_cuts.py`), set from frames, not marks: a still screen writes no frames, so a UI
test's marks run ahead of the footage, and a take's last still screen is gone. A black frame as the
idea's chat opens is dropped (`fix`). The small Reddit copy is made as before (two passes at a set rate).
