# App Store screenshots

`iphone-6.9/` (1320×2868) and `ipad-13/` (2064×2752) are upload-ready for App Store Connect → Version → App Previews and Screenshots. Upload in numbered order, the panorama's two halves first, or let `scripts/app-store-push.py screenshots` do it: it makes both sets match these files in that order, sending only the pictures that differ (it needs an App Store Connect API key; the script's first lines say where it looks for one).

Regenerate: `design/screenshots/capture.sh <raw-shots-dir>` builds the Debug app and captures every raw shot on the iPhone 18 Pro Max and iPad Pro 13-inch simulators with the dev flags (`-echo.demo`, `-echo.demoShort`, `-echo.demoTwo`, `-echo.demoLibrary`, `-echo.voiceView`, `-echo.voiceDemo` (voice mode posed mid-listen), `-echo.expandAppIcons` (Settings' App icon grid open), `-voiceOrb <name>`, `-echo.screen settings|sessions|setup`, `-echo.demoHosts` (example endpoints, never personal ones), `-theme <standard|paper|slate|terminal|amber|githubDark|claudeCode>`, `-transport chatCompletions`, `-setupDone YES`) and a 9:41 status bar; then run `/usr/bin/python3 compose.py <raw-shots-dir> design/screenshots` (the system Python has Pillow).

For 1.8 the set was taken again on 2026-10-13 the same way and came out as it was, down to the date in the iPad's status bar, so only the CarPlay slot was replaced. On 2026-10-14, when 1.8 came to carry the whole of Phone tools, the plan slots (`09-plan`, `08-ipad-plan`) made way for `09-tools` / `08-ipad-tools` (see "Phone tools slot" below); `compose.py <raw> design/screenshots 09-tools,08-ipad-tools` drew only those two. The set for 1.7 was taken on 2026-10-10 the same way; it adds three slots for what the version brought: `07-car` (iPhone only), `08-server` / `07-ipad-server` (Settings → Gateway on sample data, `-echo.demoGateway -echo.screen gateway`) and `09-plan` / `08-ipad-plan` (the agent's task list, `-echo.demoTodos`). The set for 1.6 was taken on 2026-10-06 with `PHONE=<iPhone 18 Pro Max, iOS 27>` and `PAD=<iPad Pro 13-inch (M5), iPadOS 27>` (UDIDs: two iPads share the name). `ONLY=pad` or `ONLY=phone` in front of `capture.sh` retakes one device's shots into a folder that already holds the other's; composing again leaves the untouched set byte for byte as it was.

## Two-slot panorama

`pano-01a.png` and `pano-01b.png` (in both size folders) are one composition split across two adjacent slots: the headline and the icon's orbit bridge the seam, the chat sits in the left half and the voice screen in the right. Upload them as slots 1 and 2, then continue with `03-work` through `10-privacy` on iPhone and `03-ipad-work` through `09-ipad-privacy` on iPad (the single hero and voice shots, `01` and `02`, become redundant). Regenerate with `python3 pano.py <raw-shots-dir> design/screenshots`.

## CarPlay slot

`07-car.png` shows three of the car's screens (the Ask tab, the voice card listening and speaking) stacked under its headline. They are not simulator screenshots: nothing here can open the CarPlay window. `capture.sh` has `scripts/carplay-preview.sh` draw them with CarPlay's own views at 770×360 points, the shape of a wide dashboard display, and `compose.py` (`compose_car`) sets them in bezels. The voice card's pictures are the ones that stand still (`REDDE_CARPLAY_STILL`), since a moving one is caught wherever its loop happens to be. The slot was drawn again on 2026-10-12 for 1.7.1's cards and voice card. And on 2026-10-13 for 1.8: the Ask tab with Take a Note and Short Answers (switched on) under the cards, and the voice card in solid bars with Stop and Pause in its bar. What that preview leaves out (the car's status bar, the tab bar) is missing from the slot too.

## Phone tools slot

`09-tools.png` / `08-ipad-tools.png`: a short conversation in which the agent has used the phone four times (`-echo.demoPhoneShot`: the day from the calendar, a timer, the widget, a message), with what that did outside the app set over it: on iPhone the timer counting down on the Lock Screen and the agent's widget on the Home Screen, above the phone and over its top; on iPad the widget alone, over the empty end of the conversation (whether an iPad shows an alarm's countdown hasn't been looked at). `compose.py` (`compose_tools`) cuts the two insets along their own rounded edges from `lock-timer.png` and `home-widget.png` in the raw shots folder. They are taken by `PromoVideoUITests.testToolsShotInsets` on an iOS 26.3 simulator readied by `testFunReady` (the 27.0 simulator refuses alarms), with no status bar override, which hides the countdown: `TEST_RUNNER_PROMO_VIDEO=1 TEST_RUNNER_SHOT_DIR=<raw-shots-dir> xcodebuild … -only-testing:EchoUITests/PromoVideoUITests/testToolsShotInsets`. The widget shows what the fun video's `widget` take left on it. The crop boxes in `compose.py` are for a 1320×2868 simulator.

## Privacy slot

`10-privacy.png` / `09-ipad-privacy.png` is the website's "Private by design" band as a closing slot: the gradient card, the three gold zeros and the privacy-label copy, no device shot. Pure render, no raw shots needed: `/usr/bin/python3 privacy.py design/screenshots`.

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
