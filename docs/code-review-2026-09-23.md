# Code review, 2026-09-23: correctness, efficiency, performance

Senior-engineer pass over the whole app at 7a31022 (after the 1.2 listing), with the same lens as the 09-11 review: what is wrong, what runs on the main thread that should not, what is done twice, and what can go. Five independent read-throughs (transports; conversation core and services; voice, CarPlay and intents; transcript and composer views; settings, list screens and extensions), each verified against the current code, then the fixes applied and re-reviewed as a diff. Build is clean under warnings-as-errors and strict concurrency; 150 unit tests pass.

Every numbered item below was fixed in the same change set unless marked **open**.

## Transports

1. **Stop never interrupted a hermes serve turn.** Cancelling the stream task ended `for await` without throwing, so the `session.interrupt` branch was unreachable and the agent kept running on the gateway. `Task.checkCancellation()` after the wait, and `call()` is cancellation-aware (a stopped turn fails its pending RPC at once instead of sitting out the reply or the 60 s timeout).
2. **Two sockets on a racing connect.** Model warm-up and the first send could both run `connectOnce()` while `.connecting`; the first socket and its ping loop leaked, and the session opened on socket A was driven over socket B. One shared connect task; `openSocket` cancels the previous loops before assigning.
3. **A dead cookie was trusted for 10 minutes.** `disconnect()` kept `authenticatedAt`, and `mintTicket` had no 401 retry, so a host change, gateway restart or password rotation looped the reconnect for the rest of the TTL. `disconnect()` clears it; `mintTicket` retries once after a fresh login like `rest()` does.
4. **Socket-drop RPC failures surfaced as "Unexpected response: connection closed"** and the message was not held. Pending calls now fail with `.streamLost`; a call with no socket is `.unreachable` (never left the phone, safe to retry).
5. **A cancelled reconnect loop could clobber its successor** and leave Settings on "reconnecting (try n)…" after `disconnect()`. Cancellation is checked before touching state or the task reference.
6. **Every serve frame was decoded on the main actor through `JSONValue.init(from:)`**, which throws and catches up to four `DecodingError`s per node. Frames are parsed in a detached receive loop via `JSONValue.parse` (JSONSerialization mapped once); only the finished value hops to main. `JSONValue.int` no longer traps on a non-finite or out-of-range number.
7. **Attachment bodies were base64- and JSON-encoded on the main actor** in all three transports (a 3 MB JPEG was a visible stall). `StreamingHTTP.run` takes a request builder that runs in the stream's own task; serve stages attachments from a detached task.
8. **Keychain reads on hot paths** (every dashboard REST call, view bodies, per list row). `Keychain` keeps an in-process cache invalidated on write and delete; a read that fails for any reason other than "no such item" (device locked) is not cached.
9. `ModelWarmer` did the gateway lookup before its 60 s de-dupe. Order swapped.
10. `recover()` outlived a stopped turn (90 s of polling, then a full-transcript fetch into a finished continuation). The task lives in `TurnState` and is cancelled with the turn.
11. SSE lines were re-buffered and rescanned character by character after `LineBuffer` had already split them (`feed(line:)`); one `JSONDecoder` per transport instead of one per event; `listSessions` no longer opens a WebSocket for a REST call; the six hand-rolled bearer requests in `HermesSessionsAPI` go through one `send`.
12. **Open, deliberate:** the `GET api/sessions?limit=1` probe before login stays. It costs one round trip on a cold start but keeps the password off the wire when a cookie is still live, and the tests assert the sequence. `Project.init` still round-trips each lane through JSON text to get `SessionSummary`s (only on the projects screen).

## Conversation core and services

13. **Leaving a conversation bumped its `updatedAt`**, so the list ordered by "last viewed" and relaunch reopened the wrong one. `persist()` returns early when the cached record is unchanged; regression test added. The list now orders by content change.
14. **Stop pressed while reply media was being fetched was reported as a completed turn** (widget snapshot, "Redde replied" notification, `completedAt`). Cancellation is checked after `resolveServeMedia` and the window task.
15. **Launch decoded the newest transcript synchronously before the first frame.** `ConversationStore.loadRecord(id:)` decodes off the main actor; `Conversation.init` takes the cached record if there is one and otherwise loads it in a task, applying it only if nothing was typed or sent meanwhile. Notification categories register on `.onAppear`; the delegate still attaches in `init` (iOS delivers a launch-from-banner response only to a delegate set before launch finishes).
16. `statusLine = nil` on every token fired an Observation mutation that re-evaluated the transcript body per token, defeating the 50 ms coalescer. Guarded setter.
17. Store writes ignored cancellation, so a `deleteAll` racing an in-flight write could resurrect erased conversations. `write` checks cancellation per record and before the index.
18. Truncate, regenerate and resend orphaned attachment files (up to 8 MB each) forever. `truncate` deletes files no longer referenced by messages or the outbox.
19. hermes serve `session.usage` ticks bypassed the coalescer and rewrote `messages` per tick. Buffered and applied in `flushDeltas()`.
20. `cancel()` paused the outbox even when idle (an offline retry timer was silently dropped by every load/truncate/reset). Pauses only when a turn was streaming.
21. `Settings.reset()` forgot `pushRelayURL`; `Conversation` never removed its connectivity handler or cancelled its tasks (`isolated deinit` now does); `PlainText.display` ran twelve regex passes before `notify` decided it needed a body (`@autoclosure`); `history` is copied only for the fast lane; `update` searches from the back; `TurnActivity.push` keeps one flush task and caps the preview at 160 characters; `deleteAll` uses `AttachmentFiles.deleteAll()`; summaries stay ordered on upsert so `sorted` is O(1); `ShareInbox.takePending()` decodes off the main actor; five copies of the same six-field reset became `become(...)`; `turnCount` no longer counts steer notes.
22. Siri's `messages(ids:)` rebuilt the conversation entity per message and rescanned every message through `ReadState.isRead` (a UserDefaults read each: thousands per call while Siri waited). One snapshot and one unread list per conversation.
23. `AttachmentFiles.directory` is computed once; the byte cache has a 64 MB cost limit.

## Voice, CarPlay, intents

24. **A throw from `analyzer.start`/`engine.start()` after the tap was installed left the recognizer stuck in `.preparing`** with the tap on bus 0; every later `start()` threw `.busy` until relaunch. The failure path tears down and returns to idle.
25. **A second tap during recognizer preparation left an open mic with no UI** for up to 45 s (phase was `.listening` before the recognizer was ready; `finish()` accepted `.preparing`). Generation token re-checked after every await, `cancel()` bumps it, one shared finalize task so every caller gets the same finalized text.
26. **Headphones unplugged while speaking:** output stopped but `replyTask` did not, so the next delta resumed the reply on the loudspeaker with `phase == .idle`, and hands-free reopened the mic. The task is cancelled; test added.
27. **Pause did not hold:** `schedule()` called `play()` on the next arriving chunk. A `paused` flag gates it.
28. `cancel()` killed a typed reply that was streaming when the voice screen closed. It cancels the Conversation turn only when the voice session owns it; test added.
29. A failed listen never deactivated the freshly activated session (other apps stayed paused) and set `.error` after a cancel. Guarded and released; tests added.
30. The route-change observer was installed only by proximity routing, so headphones-out during Replay/Read aloud re-routed to the loudspeaker unnoticed. Installed once in `init`.
31. After a Kokoro failure the playback loop continued while the synthesizer spoke the fallback: two voices at once. The hand-off is awaited.
32. `meterTask` wrote an `@Observable` property every 16 ms that the 60 Hz orb already sampled per frame, even with no voice screen. Deleted; `level` is written only on change.
33. Per tap callback (~94/s) an `AVAudioPCMBuffer`, a lock and an `NSError` slot were allocated on the audio thread with a scalar RMS. `vDSP_rmsqv`, preallocated buffers, one fresh buffer per ~100 ms.
34. Kokoro playback polled the main actor at 33 to 50 Hz and opened every sentence's fetch at once (a 30-sentence reply, 30 synth jobs). Per-sentence `AsyncThrowingStream`, the loop parks on a continuation, fetches start lazily with a lookahead of two. The engine is no longer torn down per reply; the voices probe is skipped if a fetch completed within 30 s; PCM conversion is off main with `vDSP_vflt16`/`vDSP_vsmul`. **Verify on device:** the Kokoro engine now stays running while the recognizer's voice-processing engine starts in hands-free; if echo cancellation misbehaves, release the output at the top of `beginListening`.
35. CarPlay left "Couldn't reach Redde" on screen with no way to dismiss, and parked on "Thinking…" during an approval. `.error` dismisses after the same beat as idle; an approval shows "Needs your phone".
36. Per hands-free turn: up to two `setCategory`s, `setActive`, and four route overrides, each posting a route change. One `setCategory`; an `activeMode` flag skips re-activation in the same mode. Also: `liveReasoning` (appended per token, never read) deleted; the sentence regex is a static literal; `isInterrupted`/`highQualityHeadsetMic` removed; `prepareAssets()` is static.
37. **Open:** `HomeWidgets` runs `PlainText.display` per widget render; storing the display form in `WidgetSnapshot.save` would remove it.

## Transcript and composer views

38. **Inline Markdown was re-parsed on every body evaluation** (`AttributedString(markdown:)` per paragraph, list item, heading and table cell) and tables could never be skipped because `MarkdownTable` took a closure. `MarkdownBlockView` is `Equatable` with `.equatable()`; the table styles its cells through the environment theme.
39. **Every diagram and formula in a page got a live WKWebView on open**, each loading the 3.5 MB mermaid bundle. The web view mounts once `.onScrollVisibilityChange` fires (latched), `Color.clear` at the remembered height until then.
40. `MermaidBlock` rebuilt its whole HTML page per body evaluation (forty `UIColor` resolutions and a triple escape, 20×/s while a reply streamed below it). Page HTML is `@State` rebuilt on a `(source, dark, theme)` key; same for `MathBlock`.
41. `VoiceView`'s whole body re-ran on every mic level tick. The orb face is its own view and the only reader of `recognizer.level`.
42. Find in conversation was O(rows × messages) per body evaluation. `matches` is `@State` recomputed on query, visibility and message count.
43. `MessageRow` without `.equatable()` in `SubagentTranscriptView` (every serve event re-ran every row); the pick-up card decoded a whole transcript on main for one line (`loadRecord`); the syntax scanner allocated an array per character and re-highlighted every block on main when the scheme flipped (precomputed markers, `Task.detached` per block, one key so a closing fence highlights once); `MarkdownImage`'s task id copied an 8 MB data URI per evaluation; `SubagentTranscriptView` could leak its listener if dismissed during `resumeLazy`; `ResolvedTheme` and the palettes are `Equatable`; one static `RelativeDateTimeFormatter`.
44. Removed: `cancelEditing()`, the unused `accent:`/`mono:` page parameters, an identical ternary, the dead `closed` flag in the math parser, `userBubbleUsesBodyText`/`replyDesign`/`headingDesign`, the double `AnyShapeStyle` wrap, a duplicate `onChange(of: messages.count)`.

## Settings, lists, extensions

45. **Open, user's call:** `aps-environment` is missing from the entitlements (project.yml regenerates them), so `registerForRemoteNotifications()` fails with "no valid 'aps-environment' entitlement string" and the push relay is dead end to end; uploads also draw ITMS-90078. Adding `aps-environment: development` under the Echo target's entitlement properties fixes it, but it needs the Push Notifications capability on the App ID, which touches provisioning. Not applied here.
46. **The share extension decoded full-size bitmaps twice** (a 48 MP photo is ~190 MB decoded in a ~120 MB extension), then re-decoded the JPEG per keystroke for a 44 pt thumbnail. `Attachment.image(fileURL:)`/`image(data:)` downsample through ImageIO at `maxImageEdge` without a full decode; the extension uses `loadFileRepresentation` and caches row thumbnails once. `Attachment.file(url:)` takes the same path for image files.
47. `SetupView` never learned a secret was already stored: reopening it with a key in the Keychain left Test and Done disabled. The flags are read on appear and set on save; Test falls back to the stored key.
48. `KanbanView` could start its live socket after the view disappeared, and `LiveBoard`'s loop held the board strongly forever. Cancellation guard, a visibility flag for the scene-phase restart, `isolated deinit { stop() }`, and the loop holds the board weakly.
49. Bulk archive/delete fired one full ledger refresh per selected row, racing each other. One sequential task, one refresh.
50. The Kokoro voice preview set the audio session by hand and never released it (other apps stayed ducked). It goes through `AudioSessionController` and deactivates on stop and on disappear.
51. The three privacy manifests declared only `CA92.1` for UserDefaults; the App Group suite needs `1C8F.1`. Added.
52. Availability flags (`CronView.backend`, `KanbanView.available`, tools/skills write access) are `@State` seeded once and re-read per refresh instead of computed per row; the ledger filter is cached on query and ledger changes; licences load once; `AppLock.biometryName` and a new `biometrySymbol` are static (the lock screen showed a Touch ID glyph for passcode-only and Optic ID devices); four near-identical secret sections became one `SecretField`, and Cloudflare now checks `Keychain.write`'s result; exports build the file off the main actor.
53. **Open, concision:** `ToolsView`/`SkillsView` are the same screen and `ConversationsView` has three hand-rolled session rows; merging them would not shorten the code without changing looks. `ReddeMark` lives in SetupView.swift while ReddeMark.swift holds `SparkShape`.

## Second pass over the fixes

Two independent reviews of the diff itself found thirteen regressions the tests would not have caught; all are fixed in the same change set.

- The voice screen's stop square always left voice mode (the "is something running" flag was read after `cancel()` idled it).
- "Erase everything" deleted the attachments folder, and the now-cached directory URL meant every later attachment write failed silently until relaunch; the folder's contents are deleted instead.
- The Kokoro voice preview stopped playback but not the engine, so `setActive(false)` failed with `.isBusy` and other apps stayed ducked.
- Find missed the streaming reply (its text grows without changing the count) and kept the previous session's match ids on switch.
- Code blocks drew one plain frame before the detached highlight landed, and could show the previous code's colors after the text changed; blocks under 4 KB highlight inline and the result carries the code it was built from.
- Lazy web blocks never mounted inside a List (Kanban card bodies), and a block with no remembered height mounted on scroll-back and shifted the page; laziness is now an environment switch set by the transcript scroll views, and a block with no remembered height boots at once.
- A serve `session.usage` tick arriving before the first delta was written onto the previous reply's footer.
- `VoiceSession.cancel()`'s "owns the turn" check was defeated by a finished reply task that was never cleared, so leaving the voice screen still killed a typed reply after the first voice turn.
- The async launch load raced Siri's cold "Ask Redde" and CarPlay: their message went to a new server session. Both await the load; a `reset()` in the window wins over it.
- A cancelled recognizer start could double-install the mic tap or tear down the newer start; starts are serialized. Stop during preparation unwinds the start instead of leaving the mic open with the session idle.
- A cancelled serve connect's tail could tear down the attempt that replaced it.

## Verification

- `xcodebuild build-for-testing`: clean, no warnings (warnings are errors).
- Unit tests: 150 in 34 suites pass; 6 skipped (iOS 27-only and the live-gateway test without a key). New tests cover the list order across switching, output-device loss mid-reply, cancel leaving a typed turn alone, listen failure releasing the session, and cancel during listen setup.
- Simulator launch: the app starts and idles on the empty-conversation screen.
- Not verified here: on-device audio (items 24 to 36) and CarPlay. Items 34 and 36 change engine and session lifetimes and deserve one hands-free session on the phone before TestFlight.
