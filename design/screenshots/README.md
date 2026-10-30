# App Store screenshots

`iphone-6.9/` (1320×2868) and `ipad-13/` (2064×2752) are upload-ready for App Store Connect → Version → App Previews and Screenshots. Upload in numbered order, the panorama's two halves first, or let `scripts/app-store-push.py screenshots` do it: it makes both sets match these files in that order, sending only the pictures that differ (it needs an App Store Connect API key; the script's first lines say where it looks for one).

Regenerate: `design/screenshots/capture.sh <raw-shots-dir>` builds the Debug app and captures every raw shot on the iPhone 18 Pro Max and iPad Pro 13-inch simulators with the dev flags (`-echo.demo`, `-echo.demoShort`, `-echo.demoTwo`, `-echo.demoLibrary`, `-echo.voiceView`, `-echo.voiceDemo` (voice mode posed mid-listen), `-echo.expandAppIcons` (Settings' App icon grid open), `-voiceOrb <name>`, `-echo.screen settings|sessions|setup`, `-echo.demoHosts` (example endpoints, never personal ones), `-theme <standard|paper|slate|terminal|amber|githubDark|claudeCode>`, `-transport chatCompletions`, `-setupDone YES`) and a 9:41 status bar; then run `/usr/bin/python3 compose.py <raw-shots-dir> design/screenshots` (the system Python has Pillow).

For 2.3 (2026-10-30) the set was taken again and reworked to tell 2.3's story (see "2.3 slots" below): after the panorama come `03-ahead`, `04-day`, `05-answers`, then the bots (`06-bots`, `07-crew`), `08-approve`, the car (`09-car`) and privacy; on iPad the same with `09-ipad-backend` in the car's place. Out went the work, rich-answers and Phone tools slots, and the backend slot on iPhone. It was taken on two simulators made for it on iOS 27.0 (an iPhone 17 Pro Max, 1320×2868, and an iPad Pro 13-inch (M5)), passed to `capture.sh` as `PHONE=<udid> PAD=<udid>`, with the Debug build of that day; the bots slots and the car's screens were drawn again too, the same ways as before. All of it is dark. Screens that show a time of day of their own (the weather, the briefings, the leaving time) carry the Mac's clock in the status bar rather than 9:41, so the two agree.

For 2.0 (2026-10-20) the bots came in as slots 3 and 4 (`03-bots`, `04-crew`, `03-ipad-bots`, `04-ipad-crew`; see "Bots slots" below), the later slots were renumbered by renaming their files, and "Make it yours" (`06-light`, `06-ipad-light`) and the server's screens (`08-server`, `07-ipad-server`) went to keep the set to ten; `compose.py <raw> design/screenshots 03-bots,04-crew,03-ipad-bots,04-ipad-crew` drew only the new four. For 1.8 the set was taken again on 2026-10-13 the same way and came out as it was, down to the date in the iPad's status bar, so only the CarPlay slot was replaced. On 2026-10-14, when 1.8 came to carry the whole of Phone tools, the plan slots (`09-plan`, `08-ipad-plan`) made way for `09-tools` / `08-ipad-tools` (see "Phone tools slot" below); `compose.py <raw> design/screenshots 09-tools,08-ipad-tools` drew only those two. The set for 1.7 was taken on 2026-10-10 the same way; it adds three slots for what the version brought: `07-car` (iPhone only), `08-server` / `07-ipad-server` (Settings → Gateway on sample data, `-echo.demoGateway -echo.screen gateway`) and `09-plan` / `08-ipad-plan` (the agent's task list, `-echo.demoTodos`). The set for 1.6 was taken on 2026-10-06 with `PHONE=<iPhone 18 Pro Max, iOS 27>` and `PAD=<iPad Pro 13-inch (M5), iPadOS 27>` (UDIDs: two iPads share the name). `ONLY=pad` or `ONLY=phone` in front of `capture.sh` retakes one device's shots into a folder that already holds the other's; composing again leaves the untouched set byte for byte as it was.

## Two-slot panorama

`pano-01a.png` and `pano-01b.png` (in both size folders) are one composition split across two adjacent slots: the headline and the icon's orbit bridge the seam, the chat sits in the left half and the voice screen in the right. Upload them as slots 1 and 2, then continue with `03-ahead` through `10-privacy` on iPhone and `03-ipad-ahead` through `10-ipad-privacy` on iPad (the single hero and voice shots, `01` and `02`, become redundant). Regenerate with `python3 pano.py <raw-shots-dir> design/screenshots`.

## CarPlay slot

`09-car.png` (`07-car` until 2.2, then `08-car`) shows three of the car's screens (the Ask tab, the voice card listening and speaking) stacked under its headline. They are not simulator screenshots: nothing here can open the CarPlay window. `capture.sh` has `scripts/carplay-preview.sh` draw them with CarPlay's own views at 770×360 points, the shape of a wide dashboard display, and `compose.py` (`compose_car`) sets them in bezels. The voice card's pictures are the ones that stand still (`REDDE_CARPLAY_STILL`), since a moving one is caught wherever its loop happens to be. The slot was drawn again on 2026-10-12 for 1.7.1's cards and voice card. And on 2026-10-13 for 1.8: the Ask tab with Take a Note and Short Answers (switched on) under the cards, and the voice card in solid bars with Stop and Pause in its bar. What that preview leaves out (the car's status bar, the tab bar) is missing from the slot too.

## Phone tools slot

Not in the set from 2.3 (compose.py no longer draws it; `compose_tools` is kept). `09-tools.png` / `08-ipad-tools.png`: a short conversation in which the agent has used the phone four times (`-echo.demoPhoneShot`: the day from the calendar, a timer, the widget, a message), with what that did outside the app set over it: on iPhone the timer counting down on the Lock Screen and the agent's widget on the Home Screen, above the phone and over its top; on iPad the widget alone, over the empty end of the conversation (whether an iPad shows an alarm's countdown hasn't been looked at). `compose.py` (`compose_tools`) cuts the two insets along their own rounded edges from `lock-timer.png` and `home-widget.png` in the raw shots folder. They are taken by `PromoVideoUITests.testToolsShotInsets` on an iOS 26.3 simulator readied by `testFunReady` (the 27.0 simulator refuses alarms), with no status bar override, which hides the countdown: `TEST_RUNNER_PROMO_VIDEO=1 TEST_RUNNER_SHOT_DIR=<raw-shots-dir> xcodebuild … -only-testing:EchoUITests/PromoVideoUITests/testToolsShotInsets`. The widget shows what the fun video's `widget` take left on it. The crop boxes in `compose.py` are for a 1320×2868 simulator.

## Bots slots

`06-bots` / `06-ipad-bots` (slots 3 and 4 until 2.3) is the chat list's Bots section on the sample bots (with the iPad's sidebar beside Quill's chat), and `07-crew` / `07-ipad-crew` a group chat's voice screen once the round has come to Quill, the third bot, with Redde's and Scout's answers above it. The demo bots in the Code theme, dark. Their raw shots (`ph-bots`, `ph-crew`, `pad-bots`, `pad-crew`) come from `PromoVideoUITests.testBotsShots`, which waits for "Quill is speaking": `TEST_RUNNER_PROMO_VIDEO=1 TEST_RUNNER_SHOT_DIR=<raw-shots-dir> TEST_RUNNER_KOKORO_URL=http://<host>:8880 xcodebuild test-without-building … -only-testing:EchoUITests/PromoVideoUITests/testBotsShots` on each simulator, with the 9:41 status bar set first. Uninstall `com.goosehouse.echo` (that id alone) from the iPad simulator before, or its sidebar lists what earlier runs left.

## Privacy slot

`10-privacy.png` / `10-ipad-privacy.png` (`09-ipad-privacy` until 2.2) is the website's "Private by design" band as a closing slot: the gradient card, the three gold zeros and the privacy-label copy, no device shot. Pure render, no raw shots needed: `/usr/bin/python3 privacy.py design/screenshots`.

## 2.3 slots

- `03-ahead` / `03-ipad-ahead`, "Ahead of your day.": the chat list's Ideas for you and Briefings decks (`-echo.demoIdeas -echo.demoBriefings -displayName Sol`), and a Leave-By Alert's banner landing over them (`-echo.demoLeaveBy`, DEBUG: a dentist's appointment, leave in five minutes, 25 minutes by car). The banner needs notifications allowed on the simulator already: run `PromoVideoUITests.testDayLeave` there once, which taps Allow. On iPad the detail pane holds the packing checklist and a booking form (`-echo.demoAsks -echo.demoAsksMore`). `capture.sh` takes a burst for the banner; pick the picture it is in.
- `04-day` / `04-ipad-day`, "Your day at a glance.": tomorrow as a timeline (`-echo.demoAgenda tomorrow`).
- `05-answers` / `05-ipad-answers`, "Answers you can use.": the weather card (`-echo.demoCards weather`) with the places card cut from `ph-places` (`-echo.demoCards places`) set over the screen's lower part (`compose_cards`).
- `08-approve` / `08-ipad-approve`, "Nothing happens without you.": an approval in plain words (`-echo.demoApprovalCard skill`: Coder's change put in place, with the chat that asked for it above) and the email to check before it sends, cut from `ph-review` (`-echo.demoAsks -echo.demoAsksReviewOnly`), set over it: over the top of the iPhone's screen, under the card on iPad.
- `09-ipad-backend`: the setup screen, as before, now in dark.

Three iPad slots are drawn larger inside the same frame (`zoom.py`, after the owner's "tighten 2, 4 and 7" on 2026-10-30): `pano-01b` (voice mode), `04-ipad-day` and `07-ipad-crew`. Their captures leave most of the 13-inch screen empty, so the screen's own pieces (the orb, the words, the buttons; the question and the day's card; the room, the face, the question, the answers, the buttons) are cut along the flat background and set 1.1 to 1.7 times larger, top to bottom in the screen's order, with the empty middle taken out; the status bar stays at the frame's scale (left out on the day, where the sidebar's colour would show in it). The frames keep their size and place, so the panorama's halves still meet as before. The boxes in `zoom.py` are for a 2064×2752 capture.

The cards set over a screen are cut from the phone's raw shots by the boxes defined just above `compose_cards` (for a 1320×2868 simulator), with a hairline round each so a dark card reads over a dark screen.

## Header and search results

`creative/header-3840x1646.png` and `creative/search-3840x2560.png` are the two creative assets App Store Connect takes on the version page under Product Page Information → Header and Search Results (new in October 2026, shown on iOS 27 and later, both optional). The header is the top of the product page; the other stands in for the screenshots in a search result.

Regenerate with `/usr/bin/python3 creative.py <raw-shots-dir> design/screenshots`. It reads `ph-voice.png` and `ph-chat-dark.png` from the raw shots, at any phone size; the ones in use were taken on an iPhone 17. Add `preview` as a third argument to also write each picture with the safe area outlined.

What Apple asks for, from its creative assets specifications and templates:

| | Shape | Size | Art safe area (x, y from the top left) |
|---|---|---|---|
| Header | 21:9 | 3840×1646, `.jpg` or `.png` | 1097–2743 across, 493–1154 down |
| Search results | 3:2 | 1920×1280 up to 3840×2560, `.jpg` or `.png` | 836–3004 across, 765–1795 down (at 3840×2560) |
| One picture for both ("universal") | 16:9 | 5244×2950, `.png` | not measured |

No alpha channel. The App Store crops to the safe area in some layouts, so the words and what matters of the phone sit inside it and everything else is there to be cropped. A video (5 to 30 seconds, 30 or 60 fps, same shapes) can stand in for either picture.

## Apple Watch

`watch/` (416×496, the Series 12, 11 and 10 size) is required once a build carries the watch app: App Store Connect → the version → App Previews and Screenshots → Apple Watch. The watch app poses itself, so no server is needed: install `DerivedData/Build/Products/Debug-watchsimulator/EchoWatch.app` on an Apple Watch Series 12 (46mm) simulator and launch `com.goosehouse.echo.watchkitapp` with `-echo.connection hermesAPI http://127.0.0.1:1 none` (the Ask screen), `-echo.preview thinking` and `-echo.preview speaking`, taking `xcrun simctl io <watch> screenshot` after each. Save them without alpha. A preview leaves its stand-in connection stored, so use a simulator that isn't paired for real work.
