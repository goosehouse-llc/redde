# Speed baseline

How fast Redde is today, as numbers, with a limit for each. The same numbers are taken again
for every release (`scripts/perf-baseline.sh`). A number over its limit means something has
got slower and needs looking at before the release ships.

- **Date:** 2026-11-11
- **Commit:** `6c80160` (main). The Debug build used for launch and memory also has the small
  launch hook described under 2. Nothing else was changed.
- **Mac:** Apple M1 Max, 64 GB, macOS 27.0 (26A428), Xcode 27.2 (27B52)
- **Simulator:** iPhone 18 Pro Max, iOS 27.0 runtime (`E542210E-6FA6-41C8-89D3-602684A707C8`)

These are simulator numbers on this Mac. Use them to compare one release with the one before
it, not as what a phone does. The phone run is still to do (see the last section).

## Re-running

```sh
scripts/perf-baseline.sh             # builds into DerivedData-perf, then measures (~25 min)
scripts/perf-baseline.sh --no-build  # measures the builds already there (~12 min)
```

The script prints each number next to its limit and marks any number over its limit
**OVER**. Output goes to `tmp/perf/` (`report.txt`, the raw launch numbers and the tour logs).
It only installs, launches and removes `com.goosehouse.echo`. It starts the stand-in model on
port 8799 (through `smoothness.sh`) and stops it when it finishes. Leave the Mac otherwise idle
while it runs, because a build or a video export running alongside changes the frame numbers.

## 1. Smoothness: late frames per tour step

**How:** `scripts/smoothness.sh 3`. This is a Debug build with `-O`, because the tour is
DEBUG-only. Each run is a fresh install with `-echo.hitches -echo.demoHeavy 24
-echo.demoLibrary -echo.tour`, and replies stream from `scripts/smooth-model.py` on
127.0.0.1:8799. `FrameMonitor` writes each step's late frames to `Library/Caches/frames.log`.

**Numbers:** the median over six runs (two batches of three), in milliseconds.

| Step | Worst frame | ms late in all | Worst-frame limit | ms-late limit |
|---|---:|---:|---:|---:|
| new conversation | 132 | 132 | 170 | |
| focus the composer | 408 | 413 | 530 | |
| type (53 letters) | 67 | 445 | 90 | 600 |
| send | 110 | 118 | 140 | |
| thinking | 9 | 9 | 40 | |
| streaming | 18 | 26 | 40 | |
| scroll while streaming | 17 | 33 | 40 | |
| streaming to the end | 88 | 270 | 130 | 400 |
| send again | 38 | 50 | 100 | |
| second reply | 56 | 412 | 80 | 550 |
| dismiss the keyboard | 78 | 82 | 100 | |
| open the list | 212 | 212 | 280 | |
| close the list | 70 | 76 | 100 | |
| open the long one from the list | 338 | 338 | 430 | |
| open a short conversation | 125 | 129 | 165 | |
| back to the long one | 270 | 273 | 350 | |
| scroll the long one | 0 | 0 | | 50 |
| open voice mode | 310 | 316 | 400 | |
| close voice mode | 24 | 50 | 120 | |
| open Settings | 440 | 440 | 560 | |
| close Settings | 72 | 103 | 100 | |

How to read these numbers:

- **The first run of a batch is much worse.** It is a one-off cost of the first time each
  screen appears. In the first batch's first run, focusing the composer took 1,188 ms, opening
  the list 1,015 ms, voice mode 875 ms and Settings 1,141 ms. In the second batch's first run
  the same four steps took 800, 367, 448 and 556 ms. The script takes the median of three runs
  so that this cost doesn't set off the limits, but the cost itself may be real on a phone the
  first time after an update.
- **The noisiest numbers are the totals while typing and streaming.** "ms late in all" for
  typing ranged from 245 to 563 ms over the six runs. Their limits are set wider to allow for
  this.
- **Some steps are already slower than on 10-28.** On 10-28 (`tmp/smoothness/table.txt`) the
  same tour gave about 330 ms for focusing the composer, 139 ms for opening the list, 262 ms
  for voice mode and 360–390 ms for Settings. Today the medians are 408, 212, 310 and 440 ms,
  which is 15–50% more. Opening the long thread has stayed flat at about 330 ms. Scrolling the
  long thread makes no late frames at all.
- **Opening the long thread freezes the screen once for about a third of a second.** It is one
  late frame of ~300–350 ms. Opening Settings freezes it once for ~440 ms.

## 2. Launch: cold launch to first frame

**How:** each build is installed fresh, launched once, then quit and launched five more times
(`xcrun simctl launch`, 2 s apart). The first launch after the install is reported on its
own, and the number given is the median of the five that follow.

- **Debug `-O` (the app's own measurement).** I added a small DEBUG-only hook in
  `Echo/App/FrameMonitor.swift` (`watchFirstFrame()`, about 20 lines). It runs only with
  `-echo.hitches`. It waits for the first time the main run loop goes to sleep with a window
  up, which is after Core Animation has committed the first frame. It then writes `# launch:
  first frame N ms after the process started` to `frames.log`, measured from the start time
  the kernel records for the process.
- **Release (no hook; from the simulator's system log).** The time from runningboard's
  `Process: … with pid: N` (the spawn) to UIKit's `deactivation reasons: … -> 0` (the app
  becomes active). On the Debug build these two markers came within 60–110 ms of the hook's
  number, always a little earlier.
- **Instruments didn't work for this.** `xcrun xctrace record --template 'App Launch'
  --device <sim> --launch -- <absolute .app path>` records without hanging. It needs the
  absolute path; a relative one fails in posix_spawn. But on the simulator its
  `life-cycle-period` table is empty, so it gives no launch phases. It should give them on a
  phone.

| Build | First launch after install | Median of the next five | Limit (first / median) |
|---|---:|---:|---:|
| Debug `-O`, hook | 4.7 s (4,670–4,923 ms) | **3.99 s** | 6.0 s / 5.0 s |
| Release, from the log | 4.7 s (4,650–4,822 ms) | **3.75 s** (3,368–3,965 ms over 10) | 6.0 s / 4.7 s |

**This is surprisingly slow.** A Release launch on the simulator spends its time in three
phases:

- **Spawn to the app's first log line: 1.8–2.0 s.** Part of this is the simulator's own launch
  handshake (SpringBoard's `_processWillLaunch` came 1.6 s after the spawn). It isn't
  necessarily the app's code.
- **First log line to the scene: ~0.2 s.**
- **Scene to the first frame: 1.4–1.5 s.**

A `sample` of a launch shows where that last phase goes. About 1.5 s of main-thread time is
inside the very first `CA::Transaction::commit` (`UIApplication _firstCommitBlock` → SwiftUI
layout). Most of it is the Swift runtime building type metadata and looking up protocol
conformances (`swift_conformsToProtocol…`, demangling) for the large generic SwiftUI view
types. `ConversationsList.body` alone takes ~425 ms of the first frame, even though the list
isn't on screen at launch. `SpeechOutput`/`KokoroPlayer` setup in `EchoApp.init` takes ~50 ms.
A phone may differ a lot here, so the phone run matters most for launch.

## 3. Memory

**How:** the Debug `-O` build on the simulator. Each figure is the physical footprint from
`vmmap -summary <pid>`, where the pid is the host process that `simctl launch` prints.

- **Idle:** a fresh install with nothing seeded, read 12 s after launch.
- **Long chat:** launched with `-echo.hitches -echo.demoHeavy -echo.autoScroll 8`. The demo
  thread is 32 turns of ~10,000 characters and is open at launch. The figure is read once
  `autoscroll:` appears in `frames.log`. The peak is vmmap's peak over the whole run.

| | Now (runs) | Limit |
|---|---:|---:|
| Idle after launch | **48 MB** (48.0–48.7) | 60 MB |
| Long chat, after scrolling up and back | **123 MB** (121–126.5) | 155 MB |
| Long chat, peak | **125 MB** (124.7–126.5) | 160 MB |

The long chat matches the 125 MB recorded after the 10-05 fix (`TranscriptPage`), so that fix
has held. The 8-second autoscroll made 0 late frames.

## 4. App size

**How:** a Release build for generic iOS, unsigned: `xcodebuild build -configuration Release
-destination 'generic/platform=iOS' -derivedDataPath DerivedData-perf
CODE_SIGNING_ALLOWED=NO`. The stripped figure comes from running `xcrun strip -rSTx` on a copy
of the executable. The zip is the whole `.app` at `zip -9`, as a rough guide to the download.
All sizes are MiB.

| | Now | Limit |
|---|---:|---:|
| App bundle (`Echo.app`) | **139.6 MB** | 170 MB |
| Executable `Echo` (with symbols) | **78.2 MB** | 95 MB |
| Executable, stripped | **29.8 MB** | 37 MB |
| Bundle zipped | **59.2 MB** | 72 MB |

Where the size goes:

- **Executable segments:** `__TEXT` 27.8 MB and `__LINKEDIT` 49.2 MB. `__LINKEDIT` is the
  symbols, which App Store thinning strips.
- **Rest of the bundle:** `Assets.car` 32.7 MB, `Watch/` 7.8 MB (its executable 6.7 MB), `Web/`
  4.2 MB, `PlugIns/` 3.5 MB (EchoControls 1.3 MB, EchoPush 0.8 MB, EchoShare 0.5 MB), and
  about 0.7 MB for each of the 17 `.lproj` folders.
- **The existing device build is smaller.** `DerivedData-rel` holds 2.5 (294) built for one
  device. It is 125 MB, because its `Assets.car` is only 17.8 MB after being thinned for that
  device. The generic build carries every device's images. Compare like with like: the script
  always measures the generic build.

## 2026-11-12: first round of fixes

Same simulator, a busier Mac (other simulators running). Medians of three tours, baseline in
brackets.

- **Launch, Release: 3.23 s (3.79 s on the same day, same binary, alternating runs).** The chat
  list is built 0.4 s after the first frame instead of in it (`SidePanel.built`), or at once if
  the panel is pulled before then.
- **Streaming.** Every message row asked `ServeMedia.mayName` (eight `String.contains` over the
  whole reply) and `BotMessages.inventedTurn` (a case-insensitive search once the reply had a
  "[") on each update; both are byte scans now. Second reply, ms late in all: 305 (412). Streaming
  to the end: 212 (270). Typing: 305 (445).
- **The rest, worst frame:** focus the composer 361 (408), open the list 160 (212), open the long
  one 317 (338), back to it 250 (270), voice 274 (310), Settings 387 (440).

What was tried and dropped:

- **Most of each screen's cost is its first time in a launch.** The same steps a second time in
  one launch: composer ~110 ms, list ~70, voice ~110, Settings ~160. Instantiating the screens'
  view types early (`MemoryLayout<X.Body>`) took 0 ms and changed nothing. A hidden generic `Form`
  drawn after launch changed nothing either. What is left is SwiftUI and UIKit building the real
  screens; warming that means building the real Settings and voice screens out of sight, which
  starts their network checks and holds the wake phrases. Not done.
- **Opening the long thread** is layout spread over every row of the page (no hot spot of the
  app's own; ~100 ms of app code over five opens). The page budget sets it:
  `-echo.pageBudget 30000` 236 ms, `15000` 180 ms, `8000` 162 ms (a floor). A smaller page means
  "Show earlier" sooner: the owner's call.
- `xctrace record` hung again on the simulator; `sample <pid>` with the tour works.

## Limits

Each limit is today's number plus about 20–30%, rounded. Where a number varied a lot between
runs, its limit is set above the worst of today's run-to-run results. Change a limit only on
purpose, and write down why here, for example when a feature that is meant to cost something
lands.

## Still to do

- **Run the same on Marta.** Not done today, because another job was using the phone. Plan
  for the phone run:
  - **Tour:** `smoothness.sh` and `-echo.tour device` need a DEBUG build. Debug builds have
    overflowed the stack at launch on Marta. Try Debug with `SWIFT_OPTIMIZATION_LEVEL=-O` (what
    `smoothness.sh` builds), and read `frames.log` off the phone.
  - **Launch:** run `xctrace record --template 'App Launch' --device <Marta> --launch` on a
    Release build. Its `life-cycle-period` table should hold the launch phases on a device.
  - **Memory:** Xcode's memory gauge, or `xctrace` with Allocations, on the long chat.
- **Prompt size per bot on the server.** `hermes -p <profile> prompt-size` for each profile.
  This needs the owner's OK to reach the server and wasn't run.
- **A Release tour.** The tour and the launch hook are DEBUG-only, so smoothness and memory
  are measured on Debug `-O`. Launch is the only number taken on both builds.
