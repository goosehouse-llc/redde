# Final review, 2026-09-11: what is not optimized that can be

Senior-engineer pass over the whole codebase with performance and efficiency as the lens. Services and transports and the voice stack were reviewed in full by two independent passes; views, bundle, launch and tests by a third. Every finding below was checked against the code as it stands at the end of 2026-09-11 (after the Redde revert and the slash menu). Ranked by impact.

The short version: the hot loops are already in good shape (delta coalescing, chunked reads, cached regexes and formatters, per-record persistence, equatable rows). What remains is main-thread work that should be off-main, per-turn churn in the voice stack, and a few per-render computations in views.

## High

1. **Every hermes serve frame is decoded on the main actor through the slowest possible JSON path.** `HermesServeClient.handle(frame:)` runs `JSONDecoder().decode(JSONValue.self, …)` per WebSocket frame, and `JSONValue.init(from:)` is a `try?` chain that throws and catches up to four `DecodingError`s per node. At token rate this is the UI thread's biggest avoidable cost on serve. Fix: decode in a `nonisolated` helper inside the receive task (`JSONSerialization.jsonObject` mapped to `JSONValue`, or a hand parser) and hop to the main actor only with the finished `Event`.
2. **Launch decodes the whole last transcript synchronously.** `Conversation.init` (built in `EchoApp.init`) calls `store.record(id:)`, which reads and decodes the record on the main thread before the first frame, and `store.sorted.first` sorts all summaries to find the newest. Fix: keep the summary at init, decode the record in a detached task after the first frame, use `max(by:)`.
3. **The share extension decodes full-size images.** `ShareViewController` loads the original bytes, decodes the full bitmap (a 48 MP photo is ~190 MB decoded, in a ~120 MB extension), then draws it again in `Attachment.image`; the row also re-decodes `UIImage(data: att.data)` on every body evaluation. Fix: `loadFileRepresentation` + `CGImageSourceCreateThumbnailAtIndex` capped at 2560 px, and store a small thumbnail on the attachment once.
4. **Attachment request bodies are built on the main actor.** All three transports base64-encode attachment bytes (which also triggers the disk read) and JSON-encode the request on main; a 3 MB JPEG is a visible stall. Fix: build the request or frames in a nonisolated function before yielding to the stream.
5. **`VoiceSession.cancel()` deactivates the audio session before the mic engine stops.** `SpeechRecognizer.cancel()` only spawns the finalize task; `removeTap`/`engine.stop()` run inside it, so `setActive(false)` fails with `.isBusy` and other apps stay paused after a cancelled turn. Fix: stop the tap and engine synchronously in `cancel()` before creating the finalize task.

## Medium

6. **Kokoro playback polls the main actor.** Two `Task.sleep` loops (20 ms and 30 ms) wake the main actor 33 to 50 times a second for the whole time-to-first-audio window and between chunks. Fix: `AsyncStream<AVAudioPCMBuffer>` per sentence and an `AsyncStream<Sentence>` queue so the loop suspends on continuations.
7. **Kokoro fires one fetch per sentence at once.** A 30-sentence reply opens as many synth jobs as the connection limit allows, competing with the sentence you are waiting to hear. Fix: keep two or three fetches in flight ahead of playback.
8. **Kokoro tears down and rebuilds the output engine every reply,** and probes `v1/audio/voices` each time. Fix: only `player.stop()` in `begin()`, stop the engine in `releaseAudio()` alone, skip the probe if a request completed in the last 30 s.
9. **Every hands-free turn re-sets the audio category and overrides the route three times** (activation, after recognizer start, on `.thinking`), each posting route-change notifications. Fix: skip `setCategory` when already `.playAndRecord`/`.voiceChat`, track an active flag, keep only the re-assert after `recognizer.start`.
10. **`VoiceSession` duplicates `Conversation`'s per-event tracking and mutates `liveReasoning` per token,** the exact per-token invalidation the 50 ms coalescing in `Conversation` avoids. Fix: expose the streaming message from `Conversation` and make `liveReasoning`, `activeTool` and `liveTranscript` computed over it.
11. **Kokoro PCM conversion runs on the main actor with a scalar loop** plus O(n) `removeFirst`. Fix: make `fetch` `nonisolated` and convert with `vDSP_vflt16` + `vDSP_vsmul`.
12. **`SSEParser` re-buffers lines `LineBuffer` already split,** rescanning each line character by character and copying it out again. Fix: add `feed(line:)` that goes straight to `consume(line:)`.
13. **`PlainText.display(replyText)` runs 12 regex passes at the end of every turn before `notify` decides whether it needs a body at all.** Fix: compute after the guard, on a prefix of the reply.
14. **Keychain reads on hot paths.** `syncAccessHeaders()` reads the Cloudflare secret before the login TTL check, so every dashboard REST call is a `SecItemCopyMatching`; `send` reads the fast-lane key every turn; `isConfigured`/`hasCredentials` are computed from view bodies. Fix: an in-process cache in `Keychain` invalidated on write and delete; read only the selected transport's key.
15. **The first serve turn spends a round trip on a probe.** `login()` does `GET api/sessions?limit=1` before the real call; `rest()` already retries on 401. Fix: drop the probe, give `mintTicket` the same 401 retry.
16. **The speech stack is rebuilt per utterance,** including two XPC lookups (`supportedLocale`, `reservedLocales`), a new analyzer and converter, and `setVoiceProcessingEnabled(true)` which recreates the IO unit. Fix: cache locale and format per process, guard on `isVoiceProcessingEnabled`, keep the converter while the mic format is stable.
17. **Find in conversation is O(n²) while active.** `TranscriptView.matches` filters all messages, and `highlight(for:)` calls it once per row. Fix: cache the match list in `@State` on `searchText`/`messages.count` change.
18. **`Date.relativeLabel` allocates a `RelativeDateTimeFormatter` per call,** from list rows. Fix: one static formatter.
19. **The conversations list sorts on every render.** `store.sorted` is computed twice per body, and the ledger list re-sorts and re-filters per keystroke. Fix: keep summaries ordered on `upsert`, and cache the filtered ledger on query change.

## Low

20. `Conversation.update` searches from the front for the streaming reply (always last); `send` copies the full transcript into `TurnRequest.history` for every transport though only the fast lane reads it.
21. `TurnActivity.replyDelta` appends every token to an unbounded `preview` and cancels and recreates a task per token; only the first 160 characters can change the banner.
22. `Project.init` round-trips each lane through JSON text to get `SessionSummary`s.
23. `AttachmentFiles.cache` has no `totalCostLimit` and inserts without a cost.
24. A fresh `JSONDecoder`/`JSONEncoder` per SSE event and per RPC frame; `sse.data.data(using:)` copies each payload.
25. The endpoint poll writes `level` unconditionally every 100 ms; the tap allocates a buffer and a lock per callback and computes RMS with a scalar loop (use `vDSP_rmsqv`).
26. `SentenceChunker` compiles its sentence regex per streamed token; `pending.count` is O(n) per token.
27. Three `AVAudioEngine`s and a synthesizer are built at launch; `warmSpeechAssets` allocates a recognizer just to call a method that touches no instance state (make it static, make the synthesizer and Kokoro player lazy).
28. `Notifier.install` registers notification categories (an XPC) inside `EchoApp.init`, before the first frame.
29. The CarPlay template is popped and pushed per reply, and its title can show the previous reply.
30. `ConversationStore.deleteAll` decodes every transcript on main just to enumerate attachments, then deletes the directory anyway; call `AttachmentFiles.deleteAll()`.
31. **Bundle.** `Resources/Web` is 4.0 MB, of which mermaid is 3.5 MB; four of the twenty KaTeX fonts are never referenced by the CSS (~60 KB). The asset catalog is 656 KB. Mermaid is the only real weight and the only fix is a slimmer diagram library.
32. **Tests.** The 8 s, 15 s and 30 s sleeps are timeouts on live or hang tests and never run on a green pass; the five 150 ms sleeps in the lifecycle tests could await a completion signal instead.

## Correctness noticed on the way

- `ConversationStore` writes with `.completeFileProtection`. A debounced save that fires after the phone locks (a background turn finishing) cannot create class-A files, so the turn is lost with a log line. Use `.completeFileProtectionUntilFirstUserAuthentication`, as `ShareInbox` does. The same family: Keychain items are `WhenUnlockedThisDeviceOnly`, so a background reconnect cannot log in once the device locks.

## Suggested order

A. Items 1, 2, 4, 5 and the file-protection fix: the main-thread and lost-turn issues, half a day.
B. Items 6 to 11: the voice stack's per-turn churn, best done together, a day.
C. Items 12 to 19: small, independent, an afternoon.
D. The low list as time allows; item 31 only if bundle size ever matters.
