# Code review, 2026-09-11

Senior-engineer pass over the whole codebase, done as four parallel reviews (services and transports; SwiftUI views; voice, audio, intents and extensions; project configuration, tests and docs). Claims that would change priorities were verified against the built app. Ranked by consequence, not by area.

**Status, end of day:** items 1 to 52 are fixed (commits from `ec149de` onward). Item 53, moving the committed PNG renders out of history, is a repo-history decision and is left open.

## Blocks the App Store upload

1. **Extensions carry hard-coded versions.** `EchoControls/Info.plist` and `EchoShare/Info.plist` say `1.0` / `1`; the app is `0.1.0` / build 74. App Store Connect rejects appex bundles whose versions differ from the container (ITMS-90473/90474). Fix: add `CFBundleShortVersionString: $(MARKETING_VERSION)` and `CFBundleVersion: $(CURRENT_PROJECT_VERSION)` to both extension `info.properties` blocks in `project.yml`.
2. **The 1024 px icon has an alpha channel.** Verified with `sips`. Upload validation rejects marketing icons with transparency (ITMS-90717). Fix: export opaque RGB from `design/icons/redde-orbit.swift` (drop the alpha bitmap info).
3. **EchoControls has no App Group entitlement.** Verified: no `entitlements` block in `project.yml`, none in the built appex. `WidgetSnapshot.load()` in the widget therefore reads a private container and the Last-reply widget can never show a reply. The Action Button and Control Center still work only because `openAppWhenRun` runs the intent inside the app process. Fix: mirror EchoShare's entitlements block for EchoControls.
4. **No privacy manifest in the extensions.** Both use `UserDefaults` (a required-reason API); Apple wants a `PrivacyInfo.xcprivacy` per bundle. Fix: copy the app's manifest into `EchoControls/` and `EchoShare/`.
5. **Bundled KaTeX and mermaid ship without licence text.** No `LICENSE` anywhere; the minified KaTeX files have their MIT headers stripped. MIT requires the notice to ship. Fix: add `Resources/Web/LICENSES/` (KaTeX MIT, KaTeX fonts OFL, mermaid MIT) and an About row in Settings that shows them.
6. **`NSLocalNetworkUsageDescription` is missing.** The primary use case is a LAN gateway; without the string, the first local-network connection fails silently on a fresh device. Fix: add it to `project.yml` info properties.

## Must fix: user-visible bugs

7. **A cancelled turn reports as completed.** `Conversation.swift` `for try await` exits silently on cancellation, so the tail still runs `finish`, saves the widget snapshot and posts "Hermes replied" with a half-written reply. Fix: `try Task.checkCancellation()` after the loop; catch `CancellationError` separately from failures.
8. **A cancelled turn's tail clobbers the next turn.** `cancel()` flips `isStreaming` synchronously, a new `send()` starts, then the old task's tail sets `isStreaming = false`, clears `currentRunID` and ends the background task the new turn owns. Fix: stamp turns with an id and gate the tail on it.
9. **Late TTS `didCancel` kills a new mic turn.** In `SpeechOutput`, a barge-in's `stopSpeaking` delivers `didCancel` after `VoiceSession` has moved to listening; `utteranceEnded` sees the old stream ended and fires `onFinished`, dropping the session to idle. Fix: an epoch per reply; ignore callbacks from an older epoch.
10. **`SpeechRecognizer.cancel()` finalises in a detached task and `start()` silently no-ops while it runs**, which is exactly the interruption-resume path. The UI shows "Listening" with no microphone. Fix: make cancel awaitable and make `start()` throw when busy.
11. **`AudioSession.deactivate()` fails silently because Kokoro's engine is still running**, so other apps stay ducked after every server-TTS reply. Fix: stop the player's engine before deactivating; log the error instead of `try?`.
12. **No echo cancellation on the input node.** `.voiceChat` mode alone does not enable it; `engine.inputNode.setVoiceProcessingEnabled(true)` is required, and must run before reading the input format. This is the real root of the parked barge-in problem.
13. **Barge-in does not cancel the server turn.** `beginListening()` cancels the local task only; tokens keep streaming and billing. Fix: call `conversation.cancel()` too.
14. **If a stream ends without `.done`, `endReply()` is never called** and the voice session hangs in speaking. Fix: call it unconditionally after the loop.
15. **Fast-lane turns can stall up to 10 s at the end** waiting on the context-window probe, and a backend that never reports a window is re-probed every turn. Fix: cache negative results and resolve the window once per transport, not per turn.
16. **Deleting the conversation being streamed resurrects it.** `delete` doesn't cancel; the tail's `persist()` re-inserts a record whose attachment files are gone. Fix: cancel first.
17. **`persist()` drops attachment-only and tool-only messages** (`!text.isEmpty` filter). Fix: keep a message if it has text, attachments, tools or reasoning.
18. **Notifications share one identifier per kind**, so a second approval replaces the first, and `clearDelivered` also removes pending requests it doesn't own. Fix: identifier per request id; drop `removeAllPendingNotificationRequests`.
19. **Ad-hoc clarify categories overwrite each other.** `setNotificationCategories` replaces the whole set. Fix: keep a dictionary of live categories and register the union.
20. **Cron "Run now" on hermes serve always times out at 30 s** because the serve REST session has a 30 s request timeout while the trigger blocks until the job finishes. Fix: per-request timeout as the API-server path already does.
21. **`waitForConnection` and the WebSocket first-frame wait ignore cancellation and have no timeout**, so an abandoned turn holds its continuation for up to 90 s and `ensureConnected()` can hang forever on a quiet host.
22. **Sheets on every subagent row.** `.sheet(item:)` inside `row(_:)` means N presenters bound to one state; SwiftUI honours one and logs a warning. Fix: hoist it to the container.
23. **Sidebar `dismiss()` on iPad has nothing to dismiss.** `ConversationsList` calls `dismiss()` after New, open and fork; inside the split view that's a no-op with no feedback. Fix: inject an `onOpened` closure.
24. **The Face ID lock leaks content.** The transcript stays in the hierarchy behind the lock view (VoiceOver can read it) and nothing covers the app-switcher snapshot. Also the Last-reply widget shows up to 600 characters on the Home Screen regardless of the lock. Fix: `.accessibilityHidden(lock.isLocked)`, cover on `.inactive`, `.privacySensitive()` on the widget and skip the snapshot when the lock is on.
25. **`IntentDialog(stringLiteral:)` treats the model's reply as a format string.** A reply containing `%@` or `%d` garbles Siri's readout. Fix: `IntentDialog("\(reply)")` and truncate.
26. **Share extension reads the whole file before the 8 MB check** and decodes up to four full-resolution images at once; a large video kills the extension before the size guard runs. Fix: check `fileSize` first, thumbnail via ImageIO, one file per attachment. A second share also overwrites the first (`pending-share.json`).

## Should fix: performance

27. **Markdown is re-parsed from scratch on every body evaluation.** `MarkdownParser.parse(text)` runs inside `MarkdownView.body`; while streaming, every flush re-parses the full accumulated text and rebuilds the block tree. This, more than the delta rate, is the source of the choppiness observed on long replies. Fix: parse in `.onChange(of: text, initial: true)` into `@State`, or cache by text hash; consider parsing only the tail block while live.
28. **The trailing code block re-highlights on every token.** Fix: skip highlighting while the block is the live trailing one, as mermaid and math already do.
29. **Attachment tiles decode full images from disk inside `body`.** Fix: thumbnail once via `CGImageSourceCreateThumbnailAtIndex` in `.task(id:)`.
30. **Day labels do a linear search per row**, O(n²) per render. Fix: compute once per messages change.
31. **The SSE reader and the Kokoro PCM reader iterate `AsyncBytes` one byte at a time**, the latter on the main actor at 48 k resumes per second per sentence. Fix: chunked reads; mark the Kokoro fetch `nonisolated`.
32. **Every serve REST call is two round trips plus a synchronous Keychain read.** Fix: authenticate once with a TTL, re-login on 401, cache the Access headers.
33. **`ConversationStore` decodes every message of every conversation on the main actor before first frame**, and every save re-encodes the whole archive, which rewrites unrelated attachment files. Fix: summaries index plus per-record files; flush on background.
34. **`projects.tree` rows are JSON-encoded and decoded again per session row.** Fix: decode the payload once into a `Decodable` type.
35. **`MessageRow` carries a closure**, defeating structural equality, so unchanged rows re-render. Fix: `Equatable` on the data fields and `.equatable()`.
36. **`AVSpeechSynthesisVoice.speechVoices()` is enumerated per sentence** and `CronJob.date` allocates up to three date formatters per call. Fix: cache both.
37. **Four Keychain reads in `SettingsView` `@State` initialisers** run on every parent render. Fix: load in `.task`.
38. **Composer inset has no background on the non-glass themes**, so bubbles scroll through it; and the single-line height probe breaks at accessibility text sizes (`height < 60`). Fix: `.background(.bar)`; size buttons with `@ScaledMetric`.

## Should fix: cleanliness and correctness

39. **`ContentView.swift` holds ten types across 870 lines**; `SettingsView` is one 300-line form that re-evaluates on every keystroke. Split into `TranscriptView`, `MessageRow`, `Composer`, `Attachments`, `ApprovalCard`; extract settings sections.
40. **Three copies of the toast**, none announcing to VoiceOver; four different relative-date renderings, one directionless. One modifier, one date helper.
41. **Duplicate intents.** `StartListeningIntent`/`AskHermesIntent` and `StartHandsFreeIntent`/`StartConversationIntent` share titles and appear twice in Shortcuts, via two different launch mechanisms. Keep the shared pair with `supportedModes: .foreground(.immediate)`.
42. **`loadServeSession` and `loadServerSession`** are near-duplicates one letter apart. Extract the common adopt step; rename the ledger one.
43. **Dead code:** `CarPlaySceneDelegate` (no manifest, no entitlement) and `VoiceSession.current` (a `nonisolated(unsafe) weak var`, which is a real data race), `Theme.colorScheme` always nil, `TurnActivity.thinking()`, `ConversationStore.record(id:)`, `ChatCompletionsTransport`'s constant `finished`. Delete or gate.
44. **Route changes ignore the reason**: unplugging AirPods mid-reply forces the answer onto the loudspeaker. Handle `.oldDeviceUnavailable` by pausing; ignore `.override` to stop the re-route loop.
45. **`onInterruptionEnded` discards `shouldResume`**, which is why the 25-attempt retry loop exists.
46. **`AskHermesTextIntent` recurses without bound on repeated 404s.** Add a retried flag.
47. **Model-supplied image URLs are fetched unconditionally**, which contradicts the "only your servers" promise and makes replies a tracking-pixel surface. Gate behind a tap or allowlist; cap size.
48. **Live Activity:** no cleanup of orphaned activities after a crash, unordered updates, and a 15-minute "done" banner. End orphans on start, serialise updates, shorten the window.
49. **Dev hooks ship in Release**, including `-echo.demoHosts` which rewrites endpoints. Wrap in `#if DEBUG`.
50. **README drift:** claims eight themes (there are five), says the CarPlay scene is declared (it is deliberately not), describes controls as using the URL hop (they don't), and prints the private tailnet hostnames in twelve places. Fix the prose; use example hosts.
51. **Tests:** the two riskiest files (`Conversation`, `HermesServeClient`) have no lifecycle tests; four suites "skip" by returning early and report green; the review-backend test reads a different environment variable than its own doc comment says; the store test sleeps 600 ms.
52. **Build settings:** no warnings-as-errors despite strict concurrency; `SWIFT_VERSION` 6.0 on a 6.2 toolchain; `keychain-access-groups` declared but unused; `bump-build.sh` cannot tell when its `sed` matched nothing.
53. **Repo weight:** 12 MB of PNGs committed (screenshots and rejected icons). Keep the generators, move renders out of history.

## Suggested order

A. Items 1 to 6 in one commit: they are configuration only and each blocks the upload.
B. Items 7, 8, 16, 17 in `Conversation`, and 9 to 14 in the voice stack: the bugs a tester will hit in the first hour.
C. Item 27 and 28 to 31: the performance work, measured against a 10 k-character reply before and after.
D. Items 18 to 26, then the cleanliness list as time allows.
