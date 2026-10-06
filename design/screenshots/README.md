# App Store screenshots

`iphone-6.9/` (1320×2868) and `ipad-13/` (2064×2752) are upload-ready for App Store Connect → Version → App Previews and Screenshots. Upload in numbered order.

Regenerate: `design/screenshots/capture.sh <raw-shots-dir>` builds the Debug app and captures every raw shot on the iPhone 17 Pro Max and iPad Pro 13-inch simulators with the dev flags (`-echo.demo`, `-echo.demoShort`, `-echo.demoTwo`, `-echo.demoLibrary`, `-echo.voiceView`, `-echo.voiceDemo` (voice mode posed mid-listen), `-echo.expandAppIcons` (Settings' App icon grid open), `-voiceOrb <name>`, `-echo.screen settings|sessions|setup`, `-echo.demoHosts` (example endpoints, never personal ones), `-theme <standard|paper|slate|terminal|amber|githubDark|claudeCode>`, `-transport chatCompletions`, `-setupDone YES`) and a 9:41 status bar; then run `/usr/bin/python3 compose.py <raw-shots-dir> design/screenshots` (the system Python has Pillow).

## Two-slot panorama

`pano-01a.png` and `pano-01b.png` (in both size folders) are one composition split across two adjacent slots: the headline and the icon's orbit bridge the seam, the chat sits in the left half and the voice screen in the right. Upload them as slots 1 and 2, then continue with `03-work`, `04-rich`, `05-backend`, `06-light` on iPhone and `03-ipad-work`, `04-ipad-rich`, `05-ipad-backend`, `06-ipad-light` on iPad (the single hero and voice shots become redundant). Regenerate with `python3 pano.py <raw-shots-dir> design/screenshots`.

## Privacy slot

`07-privacy.png` / `07-ipad-privacy.png` is the website's "Private by design" band as a closing slot: the gradient card, the three gold zeros and the privacy-label copy, no device shot. Pure render, no raw shots needed: `/usr/bin/python3 privacy.py design/screenshots`.

## Header and search results

`creative/header-3840x1646.png` and `creative/search-3840x2560.png` are the two creative assets App Store Connect takes on the version page under Product Page Information → Header and Search Results (new in October 2026, shown on iOS 27 and later, both optional). The header is the top of the product page; the other stands in for the screenshots in a search result.

Regenerate with `/usr/bin/python3 creative.py <raw-shots-dir> design/screenshots`. It reads `ph-voice.png` and `ph-chat-dark.png` from the raw shots, at any phone size; the ones in use were taken on an iPhone 17 with the Dark Glass orb (`-voiceOrb darkGlass` in place of `waveform` in `capture.sh`'s voice shot). Add `preview` as a third argument to also write each picture with the safe area outlined.

What Apple asks for, from its creative assets specifications and templates:

| | Shape | Size | Art safe area (x, y from the top left) |
|---|---|---|---|
| Header | 21:9 | 3840×1646, `.jpg` or `.png` | 1097–2743 across, 493–1154 down |
| Search results | 3:2 | 1920×1280 up to 3840×2560, `.jpg` or `.png` | 836–3004 across, 765–1795 down (at 3840×2560) |
| One picture for both ("universal") | 16:9 | 5244×2950, `.png` | not measured |

No alpha channel. The App Store crops to the safe area in some layouts, so the words and what matters of the phone sit inside it and everything else is there to be cropped. A video (5 to 30 seconds, 30 or 60 fps, same shapes) can stand in for either picture.
