# Redde

Talk to Redde, your own agent running on your own hardware, through Siri and voice. iOS app, SwiftUI, iOS 26+. (Code name and repository: Echo; the shipped name is Redde. Bundle identifiers, targets and the `echo://` URL scheme keep the code name.)

> "Hey Siri, ask Redde …" → on-device speech-to-text → HTTPS over Tailscale → Hermes gateway → llama.cpp on Paloma → streamed reply → spoken on the phone.

## Project invariant: nothing leaves the tailnet

- No third-party analytics or crash reporting. Ever.
- Speech recognition and synthesis run on the phone (SpeechAnalyzer / AVSpeechSynthesizer). The only optional remote audio service is Kokoro, which also runs on Paloma.
- Every request goes to a `*.example.ts.net` host over Tailscale. Siri is the trigger, never the brain.
- One opt-in exception: Settings → Siri → "Let Siri use Redde" (iOS 27) lets Apple Intelligence hear the message and see recent conversations. Off by default; see [Siri AI](#siri-ai-ios-27-opt-in).
- The phone holds exactly one secret: a scoped gateway key, in the iOS Keychain (`WhenUnlockedThisDeviceOnly`). Never in UserDefaults, source, or xcconfig.

## Status

| Milestone | State |
| --- | --- |
| M0 spike: text → gateway → streamed reply, TLS over Tailscale, key in Keychain | done, awaiting a real gateway key for the end-to-end run |
| M1 voice loop (on-device STT → reply → AVSpeechSynthesizer, latency metrics) | built; needs on-device tuning of the silence timeout and a real gateway key |
| M2 Siri entry (App Intent + App Shortcut, Action Button, hands-free mode) | done, including Control Center and Lock Screen controls |
| M3 polish (Kokoro streaming TTS, threading commands, settings) | Kokoro toggle, saved conversations, ctx % done |

## Backends

Three transports, switchable in Settings:

| Transport | Endpoint | Auth | What you get |
| --- | --- | --- | --- |
| Hermes API (default) | `https://hermes.example.ts.net:8642/api/sessions/{id}/chat/stream` | Bearer `API_SERVER_KEY` | The shared session ledger: every gateway session from Telegram, Discord, CLI and Redde, resumable from the list. Streams reasoning (`tool.progress` with `_thinking`), tool starts/results, and usage. |
| Hermes Dashboard | `http://hermes.example.ts.net:9119/api/ws` | Dashboard username + password (cookie login, then a 30 s WebSocket ticket) | The desktop-gateway protocol Conduit uses: JSON-RPC over one WebSocket. Live `reasoning.delta`, tool events, **tool approvals**, and **slash commands** (`/help`, `/model`, custom commands via `slash.exec` / `command.dispatch`). |
| Fast lane (direct to inference) | `http://inference.example.ts.net:11500/v1/chat/completions` | none | Straight to llama-swap / llama.cpp, no agent at all. No tools, lowest latency. Works when the gateway is down. History is sent each turn and never rewritten, so Paloma's prefix cache stays warm. |

Both ledger transports write to the same `state.db` on dchermes, so a session started by voice is visible in the dashboard and in Telegram's `/sessions`, and any of theirs can be continued from Echo. Memory saves and Basic Memory writes are agent-side tools; say "remember that…" or "write this to Basic Memory" and watch the tool chip. Settings → "Tools available to Echo" lists the toolsets the API server platform has enabled, which is where to check that `memory` and the Basic Memory MCP server are reachable.

### Skills, tools, context files

Settings has its own sections for Skills, Tools, and Context files. Skills and Tools are read from the gateway: the toolsets enabled for the API server platform, and every skill the agent knows. With the hermes serve login, Tools and Skills show switches: a toolset switch changes its platform setting in Hermes's config (`PUT /api/tools/toolsets/{name}`, the same thing the dashboard does; the API server's own `platform_toolsets.api_server` list is separate), and a skill switch stops Redde loading that skill (`PUT /api/skills/toggle`). Memory opens `~/.hermes/memories/MEMORY.md` (agent notes) and `USER.md` (facts about you), the files the memory tool writes. Context files edit `~/.hermes/SOUL.md` (persona) and `~/.hermes/ENVIRONMENT.md` in place on dchermes through hermes serve's file API (`/api/fs/read-text`, `/api/fs/write-text`); a missing file is created on first save. Skills can be created and edited from the phone: the editor writes SKILL.md through hermes serve's dashboard endpoints (`POST /api/skills`, `PUT /api/skills/content`), which reuse the agent's own `skill_manage` write path without the approval gate, and the gateway clears its skills prompt cache so the change is live on the next turn. "Draft with Redde" sends a plain-English brief through the sessions transport and drops the agent's proposed SKILL.md into the editor for review. Writing needs the hermes serve login; listing needs only the API key.

### hermes serve reconnects

The WebSocket client reconnects on its own with exponential backoff (1 s doubling to 30 s) whenever the socket drops, a `gateway.ping` goes unanswered for 10 s, or the app returns to the foreground. A turn that's mid-stream when the link drops waits up to 90 s for the reconnect, re-attaches with `session.resume`, and then either keeps streaming under the new runtime id (turn still running) or backfills the missing tail of the reply from the session's history (turn finished while away). Settings shows the connection state, including reconnect attempts.

### Share extension

"Send to Echo" appears in any app's share sheet for text, a link, up to four images, or up to four files. The sheet shows what's being shared and takes an optional note; nothing is sent to the server from there. The extension (`EchoShare`) writes the items to the App Group container (`group.com.goosehouse.echo`); the next time Echo comes to the foreground it turns them into the composer draft and pending attachments, focused and ready to send. (Extensions may not launch their host app, so there is no hand-off hop.)

### Attachments

The paperclip in the composer attaches photos (Photo Library) or files (Files app). Images are downscaled to 1600 px JPEG on the phone; other files are capped at 8 MB. What each transport can carry:

| Transport | Images | Text files | PDF / other |
| --- | --- | --- | --- |
| Hermes API | `input_image` data URL parts | inlined into the prompt | refused with a message (API server has no file parts) |
| Hermes Dashboard | `image.attach_bytes` | `file.attach` | `pdf.attach` / `file.attach`, staged on the session before `prompt.submit` |
| Fast lane | OpenAI `image_url` parts (needs a vision projector loaded in llama.cpp) | inlined | refused |

Attachment bytes are stored one file per attachment under Application Support/attachments (file-protected); the transcript JSON keeps only metadata, so history with photos stays fast to load. The share inbox is the one place bytes are encoded inline, because the extension's files aren't readable by the app.

### Model and reasoning effort

Settings → Connection → Model opens a picker fed by the active backend: the gateway's `/api/model/options` (or hermes serve's `model.options`) grouped by provider, or llama-swap's `/v1/models` on the fast lane with loaded models flagged. Reasoning effort (default / low / medium / high) sits above it for the Hermes API and Hermes Dashboard transports. The choice is sent as `model` + `provider` + `model_options.reasoning_effort` on every sessions-API turn, and as `model` / `provider` / `reasoning_effort` when hermes serve creates a session, so on hermes serve it takes effect for new conversations.

### Message queue

Nothing you send is lost to a bad connection, and you don't have to wait for a reply to ask the next thing. Both go through one outbox per conversation (`Conversation.outbox`, `Models/OutboxItem.swift`), shown as dashed bubbles under the transcript (`Views/QueuedMessageRow.swift`) and saved with the conversation, so they survive a relaunch.

- **Offline.** If a turn fails because the server couldn't be reached and nothing of the reply arrived (`NetworkFailure.isConnectivity`), the question comes back out of the transcript as "Waiting for connection" instead of an error. It retries on a 5 / 15 / 30 / 60 s backoff, when the network path comes back (`ConnectivityMonitor`), when the app returns to the foreground, and when you send something else. Messages behind it wait too, and go strictly in order. A message held longer than an hour pauses and asks for Send now, since it may no longer make sense. A dropped connection after the server had the request (`TransportError.streamLost`) and real server errors (401, bad URL) still fail normally, because resending could repeat the turn. The streaming sessions no longer set `waitsForConnectivity`, so an offline send reaches the queue in seconds instead of spinning for minutes.
- **During a reply.** Typing while a reply streams offers Steer (Hermes transports) and Send after this reply; Return does the latter. The queued question goes out as soon as the reply finishes. Stop, or a failed turn, pauses the queue: each held message then waits for Send now. Long-press a held message to edit it back into the composer, copy or delete it.
- **Voice.** If a spoken question is held, the voice screen says so ("I'll send that as soon as I can") and ends the hands-free loop rather than waiting for a reply. Siri's text Shortcuts action runs its own request and still fails immediately when offline.

Retries only run while Redde is running; a message held when iOS suspends the app goes out the next time it's opened.

### Steering

While a Hermes API or Hermes Dashboard turn is streaming, the composer's placeholder changes to "Steer the reply…" and typing shows an orange steer button next to Send after this reply (Stop returns when the field is empty). The text is injected into the running turn without cancelling it: `session.steer` on hermes serve, `POST /v1/runs/{run_id}/steer` on the sessions API (the run id comes from the stream's `run.started`). The note appears in the transcript as a small orange chip, and the status line reports whether the gateway queued or rejected it.

### Live thinking

Assistant bubbles show a "Thinking" section that streams the model's reasoning while it's live and folds behind a disclosure once the reply lands, plus a row of tool chips (running / done / failed). The voice screen shows the tail of the reasoning and the active tool while Redde works. When the agent pauses a turn over hermes serve, a card appears in both the transcript and the voice screen: **approvals** (once / this session / always / deny), **clarifying questions** (choice chips, multi-select, free text; batched questions answered per `question_id`), **sudo** (password sent straight to the gateway terminal, never stored), and **secrets** (value saved on the gateway under the named env var, or skipped). Expiry events dismiss a stale card.

Facts about the gateway that shaped the client (hermes-agent 0.21.1):

- The sessions stream is `event:`/`data:` frames ending on `done`. Reasoning arrives as `tool.progress` with `tool_name: "_thinking"`.
- Session titles must be unique on the gateway, so Echo appends a timestamp to the first question.
- Every request runs the full agent loop; there is no per-request "no tools" flag. Restrict tools with `platform_toolsets.api_server` in the gateway config, or use a profile under `/p/<name>/`.

## First run and configuration

Shipped builds have no server baked in. On first launch a setup sheet asks which backend to use, takes the URL and credentials, and offers "Test connection", which probes the server the same way the transport does (health + key check for the Hermes API server, status + login for hermes serve, `/v1/models` for an OpenAI-compatible endpoint). The same sheet is reachable from Settings → Connection → "Set up connection…". The fast lane accepts an optional API key, so it can point at a hosted OpenAI-compatible provider as well as llama.cpp.

For personal builds, a git-ignored `Echo/Resources/LocalDefaults.json` (keys: `transport`, `gatewayURL`, `serveURL`, `serveUsername`, `fastLaneURL`, `fastLaneModel`, `kokoroURL`, `kokoroVoice`, `contextWindow`) is applied once on first launch, and the live tests read their endpoints from it. It never ships and never commits.

## Transport security

Echo only talks to servers the user configures, often on private networks without public certificates, so `NSAllowsArbitraryLoads` is set with that justification (the App Review note). HTTPS is used whenever the configured URL provides it; a `tailscale serve` certificate, for instance, is a real Let's Encrypt cert and needs nothing extra.

## Background notifications

Turn on "Notify me in the background" under Settings → Voice (it asks for notification permission once). While Redde is not in front, a local notification appears when Redde needs an approval, a clarification, a sudo password or a secret; when a reply finishes (first lines as preview); and when a turn fails. The approval banner carries **Approve** (runs the command once; needs the phone unlocked) and **Deny** buttons, answered in the background without opening the app; long-press or pull down on the banner to reveal them. A single clarifying question shows its choices as buttons, or a Reply field when it is free-form; batched questions open the app. Tapping the banner itself opens the app; anything still showing is cleared when you return. Nothing fires while the app is active, because the screen already shows it. There is no push server: a background task keeps the turn streaming for the window iOS allows after you switch away (about 30 s), so long turns may finish only when you come back. Implemented in `Services/Notifier.swift`.

## Cloudflare Access

hermes serve behind Cloudflare Access instead of a tailnet: Settings → Cloudflare Access takes a service-token client ID and secret (secret in the Keychain). They're sent as `CF-Access-Client-Id` / `CF-Access-Client-Secret` on every dashboard request and on both WebSocket handshakes (gateway and kanban events). The connection test recognises the Access gate (HTTP 302/403) and says whether the headers are missing or rejected.

## Profiles

Settings → **Profile** (second section, under Name) picks which Hermes profile Redde talks to (Hermes 0.21+). The list comes from the dashboard's `GET /api/profiles`, so it needs the Dashboard login; without it a profile can be named by hand. **Default** sends nothing profile-related, so older servers behave exactly as before. Switching starts a new conversation.

- **Hermes Dashboard:** the profile rides on the calls that take one: `session.create`, `session.resume`, `session.delete`, `session.branch`, `projects.*`, `model.options`, `config.set`, `slash.exec` and `command.dispatch` over the WebSocket (params reject unknown keys, so nothing else gets it; session-bound calls such as `prompt.submit` run in their session's profile), and `?profile=` or a body `profile` on the sessions, skills, toolsets and cron REST routes (`HermesServeClient.profilePlacement`). The context and memory editors open the files under the profile's home (`path` from the profile list, else `~/.hermes/profiles/<name>`). The Kanban board is shared by every profile.
- **Hermes API:** requests go to the gateway's `/p/<profile>/` routes, which exist only with `gateway.multiplex_profiles` on, and each profile checks its own `API_SERVER_KEY` (from its `.env`). The picker stores that key per profile in the Keychain (`gateway-api-key.<profile>`). A wrong key or an unserved profile gets its own explanation in the conversation list.
- The "Ask Redde a Question" Shortcut keeps one session per profile.

## Projects

Over hermes serve, the Sessions tab starts with a **Projects** list: the gateway groups sessions by working directory and git repo (`projects.tree`), with "Home" holding everything that has no project. Tap one for its sessions, grouped by repo checkout and branch, with its own search. The flat **Recent** list follows. The Hermes API server doesn't expose working directories, so that transport shows the flat list only.

## Cron and Kanban

The sessions sheet (and the iPad sidebar) has a Sessions / Cron / Kanban switcher.

**Cron** lists the gateway's scheduled jobs with state, schedule and next run. Swipe to pause/resume or run now, tap for the prompt, last error and recent runs, “+” to create one. Schedules use the gateway's own grammar (“every 30m”, “weekdays at 9am”, a cron expression, “in 2h”, or an ISO time). Each job has a delivery target: Local (save on the gateway), Origin, or one of the gateway's configured platforms (listed by `/api/cron/delivery-targets` on serve; typed in on the API server). Over serve, “New → From a blueprint…” opens the gateway's blueprint catalog (morning brief, weekly review, price watch, …): fill the form and it becomes a job. Works over **hermes serve** (`/api/cron/jobs`, with run history and blueprints) or the **Hermes API server** (`/api/jobs`, no run history). Jobs only fire while the gateway is running.

**Kanban** shows the Hermes Dashboard's task board (a bundled plugin on hermes serve; not available through the API server). One column at a time on the phone: Triage, To do, Scheduled, Ready, Running, Blocked, Review, Done. Swipe a card forward, or pick any status from its menu; tap for details, result, comments, and “Ask Redde about this card”. New cards start in Triage unless you mark them Ready with an assignee, in which case the dispatcher picks them up. `Running` is set by the dispatcher only. Cards can be edited (title, details, priority, assignee) from the menu or the detail view; moving to Blocked or Scheduled asks for a reason, Review or Done for a summary, which the server records on the card. The board updates live over the plugin's events socket (green indicator in the toolbar) and falls back to polling when the socket can't be opened. Code in `Services/HermesAutomation.swift`, `Views/CronView.swift`, `Views/KanbanView.swift`.

## Subagents

When Redde delegates work (`delegate_task`), each child agent gets a row under the reply: its goal, task N of M, a live line with the tool count and the tool in use, then the duration and summary when it finishes. Over hermes serve, tap a row to open the child's own transcript: its stored history, then live reasoning, tool calls and text while it runs (the gateway mirrors the child's stream onto a lazily resumed session). From there you can steer the child with a note or stop it. Long-press a row to expand or copy the summary. Rows nest by depth. Over **hermes serve** these are driven by the gateway's `subagent.start/tool/progress/complete` events. The **Hermes API server** stream does not forward subagent events, so rows there are synthesized from the delegate call's goals and show "running in the background"; the results arrive in a later turn. Drawn by `Views/SubagentRows.swift`.

## Markdown

Replies render as blocks: ATX and setext headings, paragraphs with hard line breaks, nested bullet and numbered lists, task lists (`- [ ]` / `- [x]`, done items struck through), fenced code with syntax highlighting and a copy button, block quotes that can hold any block, rules, tables with column alignment, styled headers, zebra rows and inline formatting in cells, and images (`![alt](url)`, remote or data URIs) with a zoomable full-screen viewer. Inline: bold, italic, strikethrough, code spans in the theme's mono face, and tappable links in the accent colour. ```mermaid``` fences render as diagrams (with a Source toggle) and `$$ … $$` / `\[ … \]` blocks as typeset math; both use bundled mermaid.js and KaTeX in a sealed, self-sizing WebView (`Views/WebBlocks.swift`, assets in `Resources/Web`), so they work offline and never load from a CDN. Parser in `Models/MarkdownBlocks.swift`, renderer in `Views/MarkdownView.swift`, no third-party dependency.

## Export and bulk actions

Any conversation exports as a Markdown file: from the transcript's gear menu (“Export as Markdown”), or by long-pressing a session in the list. Ledger sessions are fetched and exported without opening them. The file has a heading per turn, reasoning in a collapsed details block, a one-line tool note, subagent summaries, and the reply's Markdown intact, so it pastes cleanly into Obsidian, Notes or a repo. In the sessions list, “Select” turns on multi-select with Archive and Delete for many sessions at once (Archive is ledger-only; Delete is confirmed first).

## Widgets

Two Home Screen widgets, in the same extension as the controls: **Last reply** (small, medium, large) shows the newest question and answer, Markdown stripped, and opens the app on tap; **Ask Redde** (small, plus Lock Screen circular and rectangular) opens Redde straight into listening. The app writes the latest exchange to the App Group when a reply lands and reloads the widget; nothing is fetched from the network by the widget itself. `Shared/WidgetSnapshot.swift`, `EchoControls/HomeWidgets.swift`.

## CarPlay

A CarPlay scene in Apple's voice-based conversational category (iOS 26.4+). Opening Redde on the car screen shows two rows, **Ask Redde** and **Talk with Redde** (hands-free). Tap one and the phone's voice loop runs through the car's mic and speakers with a voice-control card: Listening, Thinking, Speaking, Done. Replies are spoken only, since the category allows no text or imagery in responses. When the answer ends the card closes back onto the rows. It does not listen on launch; Apple's guidance for the category asks for voice as the primary modality on launch, so App Review may ask for that. No session list, no text, nothing to read while driving. The card is a modal template (`presentTemplate`), as CarPlay requires for `CPVoiceControlTemplate`. CarPlay owns layout, type and backgrounds, so the brand lives in the images: the rows and each voice-card state use artwork drawn in code in the app icon's navy, mist and gold (`Echo/CarPlay/CarPlayArtwork.swift`, rendered non-template so CarPlay doesn't tint it), under a "Your agent, by voice" section header. `CarPlayArtworkTests` writes the images to `$TEST_RUNNER_REDDE_ARTWORK_DIR` for a visual check. Code in `Echo/CarPlay/CarPlaySceneDelegate.swift`.

Apple granted the voice-based conversational CarPlay entitlement (`com.apple.developer.carplay-voice-based-conversation`) on 2026-09-14; it is enabled on the `com.goosehouse.echo` App ID (Certificates, Identifiers & Profiles → Identifiers → the app → CarPlay Voice Based Conversation) and declared in `project.yml`, and the Info.plist declares the CarPlay scene (CarPlay role → `CarPlaySceneDelegate`). Declaring the scene turns on multiple-scene support, which once stopped `echo://` opens from widgets reaching the app on the phone, so the WindowGroup routes every external event to the existing window (`handlesExternalEvents` in `EchoApp`). After changes here, re-check the Action Button, Control Center and widget paths on a device. On iPad, multiple-scene support also allows more than one Redde window. Siri ("Hey Siri, ask Redde…") already works in the car without any of this.

To preview the car screens before the entitlement arrives, run `scripts/carplay-simulator.sh`. It builds a separate, git-ignored simulator project with the scene manifest and entitlement switched on, so the committed config and the iPhone build are untouched. The voice conversational key needs an iOS 26.4+ simulator; on older simulators pass `com.apple.developer.carplay-maps` as a stand-in. Then open Simulator → I/O → External Displays → CarPlay and tap Redde. Speech recognition doesn't work in the simulator, so it previews layout and taps, not a real voice turn.

## Calendar for the agent

Redde itself has no Calendar access. Instead, `companion/calendar-mcp` is a small MCP server for a Mac that syncs your calendars through iCloud. It gives Hermes read-only calendar tools over the tailnet, behind a bearer token, and neither the app nor Hermes changes. Install and Hermes setup are in its README.

## Appearance

Five themes, in this order: Default, Paper, Slate (grey-blue, steel accent), Terminal, Code. Settings → Appearance has a Light / Dark / System switch above the theme list, and every theme has both faces: Paper is parchment by day and dark ink after dark, Terminal and Code keep their mono type on black/charcoal or on pale green/warm grey. Colours are dynamic (`Theme.dyn`), so the whole app, the diagrams and the Live Activity follow. Stored as `appearance`; the app renders in `Settings.effectiveColorScheme`.

## Keyboard shortcuts (iPad, Mac)

⌘N new conversation · ⌘K sessions · ⌘1 / ⌘2 / ⌘3 Sessions / Cron / Kanban in the list · ⌘L focus the composer · ⌘↩ send · ⌘. stop the reply · ⌘⇧V voice mode · ⌘E export as Markdown · ⌘, settings. On the voice screen, space toggles the mic and Esc closes. Hold ⌘ on an iPad keyboard to see the overlay.

## Small things

The transcript only auto-scrolls while you're at the bottom; scroll up to read and a jump button appears (it points at the live reply while streaming). Day separators mark where a session crosses midnight. Haptics: a nudge when Redde needs you, a tick when a reply lands, a buzz on failure; VoiceOver hears "Redde replied". An orange strip under the title shows hermes serve reconnecting. Long-press a reply for Copy, Copy thinking, Share, Select text (a plain selectable view) and its timestamp.  Settings ends with the version and build; tap to copy it into a bug report.

## Replay

On the voice screen, the replay button next to Hands-free speaks the last reply again with the current voice (on-device or Server TTS). Tapping the mic while it plays interrupts, as with any reply. A replay is not a new turn: metrics and history are untouched, and hands-free resumes listening afterwards.

## The ctx figure

The footer's `ctx` is context occupancy, not spend. On **hermes serve** it comes from the gateway's own `context_used` / `context_max` (pushed as `session.usage` during a turn and repeated on `message.complete`). On the **fast lane** it is the one call's prompt + completion tokens against the detected window. The **Hermes API server** only reports the session's running totals across every API call, which is a billing number, not a context size, so the footer says `session 251k tok` there instead of a percentage. The demo conversation also updates that line.

## Streaming smoothness

Tokens arrive every few milliseconds; applying each one would re-parse the Markdown, re-highlight code and re-scroll. `Conversation` buffers text and reasoning deltas and applies them about 20 times a second (flushing immediately around tool events, interrupts and the end of the turn, so ordering and metrics are exact). Code blocks re-highlight only when their text or the colour scheme changes. A diagram or formula that is still streaming renders as a plain code block until its fence closes, and the WebView renderers debounce reloads by 400 ms.

## Long sessions

The transcript renders the newest 60 messages of a session; a "Show earlier messages" button at the top reveals the previous 60 without losing your place. Fenced code blocks are syntax-highlighted (Swift, Python, JavaScript/TypeScript, shell, JSON, YAML, Go, Rust, SQL, HTML, C-family, Ruby, CSS; anything else gets strings, numbers and comments) with light and dark palettes, by `Services/SyntaxHighlighter.swift`. No third-party dependency.

## Live Activity

While a turn runs, a Live Activity shows in the Dynamic Island and on the Lock Screen: thinking, the tool in use, then a preview of the reply as it streams, with a running timer. When the reply finishes the activity shows "Redde replied" with the first lines and stays for 15 minutes; a failure or cancel shows why. Tapping it opens Echo. Updates are throttled to once a second. Toggle it under Settings → Voice. Drawn by the `EchoControls` widget extension (`EchoTurnLiveActivity`), driven by `Services/TurnActivity.swift`.

## iPad and accessibility

On regular-width layouts (iPad, Stage Manager) the session list becomes a sidebar in a `NavigationSplitView` and the transcript and composer cap at 820 pt and center; on iPhone the list stays a sheet. Custom controls carry VoiceOver labels and hints (mic phases, composer buttons, tool chips, attachments, interrupt cards); theme swatches are hidden from VoiceOver; message bubbles announce who spoke.

## App lock

Settings → Lock → "Require Face ID" (or Touch ID / passcode, whatever the device has) gates the app. Turning it on runs an authentication immediately so a broken sensor can't lock you out later. Echo locks on launch and whenever it has been in the background longer than the chosen grace period (immediately, 1, 5, 15 or 60 minutes); the lock screen blurs the content underneath and the device passcode is the fallback. Siri, control and share-sheet requests that arrive while locked run once you've unlocked. Background Shortcuts runs are not gated: they never show UI, and the credentials they use are protected by the Keychain rather than the lock.

## Store listing pages

**Name.** The App Store listing is “Redde for Hermes” (so it surfaces when someone searches “hermes”); the home-screen label and in-app strings say “Redde” when they mean the assistant. The connection methods use their mainstream names: “Hermes API” (the gateway's API server), “Hermes Dashboard” (`hermes serve`) and “OpenAI-compatible” (straight to a model server); Siri also answers to “Hermes” and “Sol” (`INAlternativeAppNames`). The bundle ID stays `com.goosehouse.echo` and the Xcode targets keep their Echo names. SKU: `redde-ios` (fixed when the record was created; internal only).

The privacy policy and support page are published at https://legal.goosehouse.org/redde/privacy and https://legal.goosehouse.org/redde/support (the same Cloudflare static site that hosts the Homeschool Wizard policy, from `HomeschoolWizard/legal`; deploy with `npx wrangler deploy` there). The Markdown sources live in `docs/`.

## Building

Requires Xcode 27 (the iOS 27 SDK, for the Siri AI App Schemas; the deployment target stays iOS 26) and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The `.xcodeproj` is generated and git-ignored.

```sh
xcodegen generate
open Echo.xcodeproj
```

`Echo/Resources/PrivacyInfo.xcprivacy` is the privacy manifest (no tracking, no collected data, UserDefaults declared under reason CA92.1). `scripts/bump-build.sh` sets the build number to the commit count and regenerates the project; run it before archiving so every upload has a new build number.

Signing is automatic under the Goosehouse LLC team. Distribution is personal (direct install / TestFlight), so no App Store review constraints apply.

### First run

1. Settings → paste the scoped `API_SERVER_KEY` → Save key. It goes straight to the Keychain and is not shown again.
2. Send a message. The footer under each reply shows time-to-first-token and total time as measured on the phone.
3. Try it on cellular with Tailscale on, not just Wi-Fi.

### Tests

```sh
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Unit tests cover the SSE parser, both stream decoders, the sentence chunker, and markdown stripping. The live tests hit the real fast lane and gateway when reachable and skip otherwise. Paloma has no microphone, so on-device STT is tested by pushing a synthesized WAV (`EchoTests/Fixtures`) through the same converter + SpeechAnalyzer pipeline the mic uses.

## Voice loop

Tap the mic in the composer to enter voice mode. One button, and the phase tells you what a tap does: start listening, stop listening, cancel thinking, or barge in while Redde is speaking. The turn ends on its own after about a second of silence once something has been heard. "Hands-free" reopens the mic after every reply.

Each turn's footer shows where the time went, measured on the phone:

| Metric | Meaning |
| --- | --- |
| end→word | end of your speech to the first spoken word. The number that matters. Target < 2.5 s. |
| finalize | SpeechAnalyzer finalization after silence |
| TTFT | request sent to first token from Paloma |
| TTS start | first token to audio actually playing |
| model | request sent to last token |
| ctx | tokens this turn (prompt incl. history + reply) as a percentage of the model's context window. The fast lane reads the window from llama.cpp via `/upstream/<model>/props`; the gateway path uses the Settings value (default 131072). |

Say "stop listening", "that's all", "goodbye", or "thanks" on its own and Echo ends the loop instead of sending it to Redde. The name can ride along ("thanks, Redde"; "Hermes" still works too).

### AirPods

- **Microphone.** When the connected headset supports iOS 26's full-bandwidth Bluetooth recording (recent AirPods), the voice session uses `.bluetoothHighQualityRecording` (default mode, HFP as the fallback) instead of the narrowband call mic. On any headphones or Bluetooth headset the recognizer also leaves the engine's voice processing off, since the headset keeps the reply out of the mic and the processing only dulls it; on the phone's speaker, earpiece and CarPlay it stays on for echo cancellation. `AudioSessionController.onHeadphones` / `highQualityHeadsetMic`, logged on every route change.
- **Press to talk.** While the voice screen is open Redde is the Now Playing app (`HeadsetControls`): an AirPods stem press, the Lock Screen / Control Center play-pause, and a car's play-pause button all do what tapping the mic does (listen, send, cancel, barge in). The AirPods mute gesture during listening is treated as a press and unmuted again. The Lock Screen shows "Redde" with the current phase.
- **Taking them out.** Losing the headset mid-reply stops speaking (Apple's guidance: pause, don't move to the loudspeaker); mid-question it stops listening instead of carrying on through the phone's mic, and ends hands-free.
- **Announce.** Settings → Voice → "Announce on AirPods" makes Redde's background alerts time-sensitive (`com.apple.developer.usernotifications.time-sensitive`), which is what lets Siri read them through AirPods once Announce Notifications is on for Redde in iOS Settings. Time-sensitive alerts also reach you in a Focus, hence off by default.

Siri itself already works through AirPods ("Hey Siri, ask Redde"). None of the headset paths above can be exercised in the simulator; they need a device and the headset.

## Siri and the Action Button

Echo registers two App Shortcuts, named "Ask Redde" and "Talk with Redde". "Hermes" is an alternate app name, so these work with either name:

| Say | What happens |
| --- | --- |
| "Hey Siri, ask Redde" / "talk to Redde" (or "ask Hermes") | Opens Echo in voice mode and starts listening for one question |
| "Hey Siri, chat with Redde" / "Redde hands-free" | Same, with hands-free on |

Siri is the trigger only. It never hears the question: the app opens first and its own on-device recognizer listens. This is deliberate. A parameterized phrase ("ask Redde ⟨question⟩") would route the dictation through Siri's own recognizer and is unreliable for long free-form questions.

**Shortcuts action.** "Ask Redde a Question" takes a text parameter and returns the reply as text, so it works inside your own shortcuts and automations ("Get clipboard → Ask Redde → Speak"), and Siri speaks the reply when a shortcut runs by voice. It runs in the background on the transport selected in Settings; on the Hermes API and Hermes Dashboard transports the exchanges accumulate in a "Shortcuts" session in the ledger rather than the open conversation. Apple doesn't allow free-text parameters in Siri phrases, so this is a Shortcuts building block, not a "Hey Siri, ask Redde ⟨anything⟩" phrase.

**Control Center, Lock Screen, Action Button.** The `EchoControls` widget extension provides two controls, "Ask Redde" and "Talk with Redde" (hands-free). Add them from Control Center's edit mode, the Lock Screen's control slots, or Settings → Action Button → Controls. A control runs in the widget extension, so its intent asks the system to open the app (`openAppWhenRun`) and leaves a request in the App Group (`Shared/LaunchFlag.swift`); the app consumes it on activation and starts listening. The `echo://listen` URL scheme remains for the Home Screen widget and Siri. Note the dev flags (`-echo.demo` and friends) exist in Debug builds only.

## Siri AI (iOS 27, opt-in)

With Settings → Siri → **Let Siri use Redde** on, Redde is a messaging app as far as Siri AI is concerned: it adopts the iOS 27 App Schemas in the Messages domain (`.messages.*`), with your agent as the contact, each saved conversation as a conversation and each turn as a message. That makes free-form requests work without opening the app:

| Say | What happens |
| --- | --- |
| "Hey Siri, ask Sol in Redde whether the backup ran" / "text Sol …" | `ReddeSendMessageIntent` sends it as a turn in the open conversation, waits up to 20 s (`SiriTurn.replyBudget`) and Siri speaks the reply. Slower replies: Siri says "Sent", the turn keeps running, and the usual "Redde replied" banner brings the answer back |
| "Reply …" to an announced "Redde replied" banner | The banner carries the reply's entity (`appEntityIdentifiers`), so Siri knows which conversation you mean |
| "Siri, summarize this" / "reply to that" on screen | Transcript rows carry `appEntityIdentifier`, so Siri knows which message you mean |
| "Draft a message to Sol …" | Redde opens with the text in the composer |
| "Edit my last message to say …" / "Unsend that" | Edit & resend / remove from that turn on (serve rewinds the gateway; the API-server ledger keeps its rows) |
| "Read my messages from Sol" / "Mark that as unread" | Replies that landed while you were away are unread until you open the conversation (`ReadState`) |
| "Find the conversation about the Proxmox outage" | People, the 30 newest conversations and their last 30 turns are in Spotlight (`SiriIndex`); App Lock on = titles only |

Details:

- **Same path as typing.** A Siri message goes through the app's one `Conversation` (`Conversation.current`), so it lands in the transcript, the ledger, the Live Activity and the widget like any other turn. The Messages schema addresses people, not conversations, so Siri messages and drafts always go to the open conversation. Sending behind a running reply queues it, as in the app.
- **The agent is the only contact.** It answers to the name in Settings → Name, "Redde", "Hermes" and "Sol". Anyone else is refused.
- **Locked phone.** Send, edit and unsend require authentication, since the turn uses the gateway key (`WhenUnlockedThisDeviceOnly`).
- **Off means off.** With the switch off every query returns nothing, every intent refuses with a pointer to Settings, and turning it off deletes Redde's Spotlight entries. The switch only appears on iOS 27; on iOS 26 the hooks (`SiriHooks`) are no-ops.
- **Not supported:** scheduled sends (ask the agent for a cron job), audio-only messages, locations. Photos Siri passes along are attached like composer photos; links are appended to the text.
- **Needs** iOS 27, an iPhone that runs Siri AI (iPhone 15 Pro or later), English, and a region where Siri AI is available (not the EU at launch). "Hey Siri, ask Redde" (open and listen) keeps working everywhere.
- Code: `Echo/Intents/Siri/SiriEntities.swift` (entities, enums, queries, `SiriCatalog`), `Echo/Intents/Siri/SiriMessageIntents.swift` (the five intents, `SiriTurn`), `Echo/Services/SiriIntegration.swift` (`SiriAccess`, `ReadState`, `SiriIndex`, `SiriHooks`). Tests: `EchoTests/SiriSchemaTests.swift`.

### Conversations

Every conversation with at least one turn is saved on the phone (JSON in Application Support, complete file protection). The list button in the toolbar shows them newest first; tap to resume, swipe to delete. On launch Echo reopens the most recent one. Nothing is synced anywhere.

### Session housekeeping

In the Hermes API list: search (title, preview, source), swipe right to pin or unpin (pinned sessions sort first), swipe left to archive or delete, and long-press for rename, pin, fork, archive, delete. Rename/pin/archive go through `PATCH /api/sessions/{id}` on either surface; fork uses `POST /api/sessions/{id}/fork` on the API server and `session.branch` on hermes serve. Archived sessions leave the list but stay in the gateway's database.

### Usage and cost

Each session row shows the ledger's token totals ("▲ input ▼ output") and the gateway's cost estimate when it's non-zero. Long-press → "Usage & cost" opens the full breakdown: input, output, reasoning, cache read/write tokens, estimated and actual cost, message, tool-call and API-call counts. Local models on Paloma report zero cost.

### Kokoro voice

Settings → Voice output → "Kokoro on Paloma" speaks replies with the `am_onyx(2)+bm_george(1)` blend from the Kokoro server on port 8880. Each sentence is one request with `response_format: pcm, stream: true`; the 24 kHz 16-bit mono stream is decoded to float buffers about 100 ms at a time and scheduled on an `AVAudioPlayerNode`, so audio starts roughly 100 ms after the sentence is sent. Sentences are fetched ahead and played in order. If a request fails, that sentence is spoken by the on-device voice instead.

Dev hook: launch with `-echo.autoVoice` to open voice mode and start listening immediately.

## Layout

```
Echo/
  App/EchoApp.swift                      entry point
  Models/Message.swift                   transcript rows + per-turn latency metrics
Shared/Attachment.swift                  images/files attached to a message (app + share extension)
Shared/ShareInbox.swift                  App Group hand-off from the share extension
Shared/EchoTurnAttributes.swift          Live Activity payload (app + widget extension)
EchoShare/                               share extension UI
  Services/Keychain.swift                the one secret
  Services/Settings.swift                non-secret config (UserDefaults)
  Services/Conversation.swift            observable store: history, streaming task, thread id
  Services/Transport/HermesTransport.swift        protocol, shared streaming HTTP, event types
  Services/Transport/SSEParser.swift              incremental SSE parser
  Services/Transport/HermesSessionsTransport.swift  ledger: sessions API streaming + REST (list, messages, toolsets)
  Services/Transport/HermesServeClient.swift        hermes serve: cookie login, ws-ticket, JSON-RPC over WebSocket
  Services/Transport/HermesServeTransport.swift     one turn over hermes serve; slash commands; approvals
  Services/Transport/JSONValue.swift                small dynamic JSON for the RPC frames
  Services/Transport/ChatCompletionsTransport.swift  llama-swap fast lane
  Services/Voice/AudioSession.swift      one .playAndRecord session for the whole loop, interruptions
  Services/Voice/SpeechRecognizer.swift  iOS 26 SpeechAnalyzer, on-device only, our own endpointing
  Services/Voice/SpeechOutput.swift      AVSpeechSynthesizer fed sentence-by-sentence while streaming
  Services/Voice/VoiceSession.swift      listen → send → speak state machine + VoiceMetrics
  Services/Voice/KokoroPlayer.swift      streaming PCM from Kokoro on Paloma → AVAudioPlayerNode
  Services/Voice/StopPhrase.swift        "that's all" / "stop listening" detector, never sent to the model
  Services/ConversationStore.swift       saved conversations (JSON in Application Support, file-protected)
  Services/ContextWindowProbe.swift      reads n_ctx from llama.cpp for the ctx % figure
  Services/AppLock.swift                 biometric gate + grace period
  Services/ConnectionTester.swift        per-backend "test connection" probes
  Views/SetupView.swift                  first-run configuration sheet
  Services/TurnActivity.swift            Live Activity driver (throttled updates)
  Services/Notifier.swift                Background notifications + background-task extension
  Views/SubagentRows.swift               Delegated child agent rows under a reply
  Services/LaunchRouter.swift            intents → UI bridge
  Intents/AskHermesIntent.swift          App Intents + App Shortcuts (Siri)
  Intents/AskHermesTextIntent.swift      Shortcuts action with a question parameter → reply text
Shared/ControlIntents.swift              intents + echo:// URL used by the controls extension
EchoControls/                            widget extension: Control Center / Lock Screen buttons
  Views/InterruptCard.swift              approval / clarify / sudo / secret cards
  Views/ModelPickerView.swift            model + reasoning effort picker per transport
  Views/SkillEditorView.swift            create/edit SKILL.md, Draft with Redde
  Views/ContextFileEditorView.swift      SOUL.md / ENVIRONMENT.md editor
  Views/ToolsetsView.swift               Skills list and Tools list
  Views/                                 transcript, composer, settings, full-screen voice mode
EchoTests/                               parser/decoder unit tests, live tailnet tests, WAV-driven STT test
```

## Decisions log

- **New app, not a Conduit fork.** The voice loop needs tight control of the audio session and intent lifecycle. Conduit stays the rich chat client; Echo is voice-first.
- **Hermes sessions API as the primary transport.** It is the shared ledger. The Responses API transport was built first and removed once the ledger worked; the fast lane stays as the "gateway is down" path.
- **v1 is chat only.** Nothing in Echo bypasses the server-side confirm-token gating on destructive Home Assistant actions.
- **iPhone and iPad.** Same app; iPad gets a sidebar layout. Watch/CarPlay change the audio-session and intent design and are deferred.
- **On-device STT first** (SpeechAnalyzer, iOS 26). Whisper on Paloma is a later option if accuracy demands it.
- **AVSpeechSynthesizer first**, Kokoro as a toggle in M3 with PCM streaming (24 kHz, 16-bit mono) into an `AVAudioPlayerNode`.

## Contributing

Pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md); first-time contributors sign the [CLA](CLA.md) with a one-line comment when the bot asks.

## License

[FSL-1.1-MIT](LICENSE.md), the Functional Source License. You can read, use, modify and self-host Redde for any purpose except offering a competing commercial product. Each release becomes MIT on its second anniversary.

The Redde name and app icons are not licensed for use in other products. Bundled third-party code keeps its own license: KaTeX and Mermaid (MIT), KaTeX fonts (OFL).
