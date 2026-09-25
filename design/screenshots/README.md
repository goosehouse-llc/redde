# App Store screenshots

`iphone-6.9/` (1320×2868) and `ipad-13/` (2064×2752) are upload-ready for App Store Connect → Version → App Previews and Screenshots. Upload in numbered order.

Regenerate: `design/screenshots/capture.sh <raw-shots-dir>` builds the Debug app and captures every raw shot on the iPhone 17 Pro Max and iPad Pro 13-inch simulators with the dev flags (`-echo.demo`, `-echo.demoShort`, `-echo.demoTwo`, `-echo.demoLibrary`, `-echo.voiceView`, `-echo.voiceDemo` (voice mode posed mid-listen), `-echo.expandAppIcons` (Settings' App icon grid open), `-voiceOrb <name>`, `-echo.screen settings|sessions|setup`, `-echo.demoHosts` (example endpoints, never personal ones), `-theme <standard|paper|slate|terminal|amber|githubDark|claudeCode>`, `-transport chatCompletions`, `-setupDone YES`) and a 9:41 status bar; then run `/usr/bin/python3 compose.py <raw-shots-dir> design/screenshots` (the system Python has Pillow).

## Two-slot panorama

`pano-01a.png` and `pano-01b.png` (in both size folders) are one composition split across two adjacent slots: the headline and the icon's orbit bridge the seam, the chat sits in the left half and the voice screen in the right. Upload them as slots 1 and 2, then continue with `03-work`, `04-rich`, `05-backend`, `06-light` on iPhone and `03-ipad-work`, `04-ipad-rich`, `05-ipad-backend`, `06-ipad-light` on iPad (the single hero and voice shots become redundant). Regenerate with `python3 pano.py <raw-shots-dir> design/screenshots`.

## Privacy slot

`07-privacy.png` / `07-ipad-privacy.png` is the website's "Private by design" band as a closing slot: the gradient card, the three gold zeros and the privacy-label copy, no device shot. Pure render, no raw shots needed: `/usr/bin/python3 privacy.py design/screenshots`.
