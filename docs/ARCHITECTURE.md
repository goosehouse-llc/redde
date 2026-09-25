# Architecture

How Redde works, for contributors. For what it is and how to build it, see the [README](../README.md).

## Principles

- **Your server, nothing else.** Requests go only to the servers the user configures. No analytics,
  no crash reporting, no service of our own in the request path.
- **On the device where possible.** Speech recognition (SpeechAnalyzer) and the built-in voice
  (AVSpeechSynthesizer) run on the phone. The only optional remote audio service is a Kokoro server
  the user runs.
- **Secrets in the Keychain.** Keys and passwords are stored `WhenUnlockedThisDeviceOnly`, never in
  UserDefaults, source or config files.
- **One opt-in exception:** Settings → Siri → "Let Siri use Redde" (iOS 27) lets Apple Intelligence
  hear messages and see recent conversations. Off by default; see [Siri AI](#siri-ai-ios-27-opt-in).

## Connections

Three, chosen under Settings → Connection:

| Connection | Endpoint | Auth | What you get |
| --- | --- | --- | --- |
| Hermes Dashboard | `hermes serve`, `ws://…:9119/api/ws` | Dashboard username + password (cookie login, then a 30 s WebSocket ticket) | The desktop-gateway protocol: JSON-RPC over one WebSocket. Live `reasoning.delta`, tool events, approvals, and slash commands (`slash.exec` / `command.dispatch`) |
| Hermes API | The gateway's API server, `https://…:8642/api/sessions/{id}/chat/stream` | Bearer `API_SERVER_KEY` | The shared session ledger: every gateway session from Telegram, Discord, the CLI and Redde, resumable from the list. Streams reasoning (`tool.progress` with `_thinking`), tool starts and results, and usage |
| OpenAI-compatible | `…/v1/chat/completions` (llama.cpp, llama-swap, vLLM, Ollama, a provider) | Optional API key | Straight to a model, no agent: no tools, lowest latency, works when the gateway is down. History is sent each turn and never rewritten, so a llama.cpp prefix cache stays warm |

Both Hermes connections write to the same `state.db`, so a session started by voice shows up in the
dashboard and in Telegram's `/sessions`, and any of theirs can be continued here. Memory saves and
other writes are agent-side tools: say "remember that…" and watch the tool chip.

Screens ask `SessionBackend` for the current backend instead of branching on the connection.

### Skills, tools, context files

Skills and Tools are read from the gateway: the toolsets enabled for the API server platform, and
every skill the agent knows. With the Dashboard login they also get switches: a toolset switch
changes its platform setting in Hermes's config (`PUT /api/tools/toolsets/{name}`), and a skill
switch stops Redde loading that skill (`PUT /api/skills/toggle`).

Memory opens `memories/MEMORY.md` (agent notes) and `memories/USER.md` (facts about you); Context
files edit `SOUL.md` (persona) and `ENVIRONMENT.md`, all in the profile's Hermes home, through the
dashboard's file API (`/api/fs/read-text`, `/api/fs/write-text`). The Hermes API server has no file
endpoints (its capabilities report `memory_write_api: false`), so these need the Dashboard login, and
Settings says so when it's missing. Skills can be created and edited from the phone
(`POST /api/skills`, `PUT /api/skills/content`); "Draft with Redde" asks the agent for a SKILL.md
and drops it into the editor for review.

### Profiles

Settings → Profile picks the Hermes profile (Hermes 0.21+). The list comes from the dashboard's
`GET /api/profiles`; without the Dashboard login a profile can be named by hand. **Default** sends
nothing profile-related, so older servers behave as before. Switching starts a new conversation and
reloads the conversation list.

- **Hermes Dashboard:** WebSocket params reject unknown keys, so `profile` goes only on the calls
  whose contracts take it (`session.create/resume/delete/branch`, `projects.*`, `model.options`,
  `config.set`, `slash.exec`, `command.dispatch`); session-bound calls run in their session's
  profile. REST calls carry it as `?profile=` or in the body, route by route
  (`HermesServeClient.profilePlacement`). File editors use the profile's home from the profile list,
  else `~/.hermes/profiles/<name>`. The Kanban board is shared by every profile.
- **Hermes API:** requests go to the gateway's `/p/<profile>/` routes, which exist only with
  `gateway.multiplex_profiles` on, and each profile checks its own `API_SERVER_KEY`. The picker
  stores that key per profile in the Keychain (`gateway-api-key.<profile>`). A rejected key or an
  unserved profile gets its own explanation in the conversation list.
- The "Ask Redde a Question" Shortcut keeps one session per profile.

### Dashboard reconnects

The WebSocket client reconnects with exponential backoff (1 s doubling to 30 s) whenever the socket
drops, a `gateway.ping` goes unanswered for 10 s, or the app returns to the foreground. A turn that
is mid-stream waits up to 90 s for the reconnect, re-attaches with `session.resume`, and either keeps
streaming or backfills the missing tail of the reply from history.

### Gateway facts that shaped the client

- The sessions stream is `event:`/`data:` frames ending on `done`; reasoning arrives as
  `tool.progress` with `tool_name: "_thinking"`.
- Session titles must be unique on the gateway, so the first question gets a timestamp.
- On the Dashboard, `message.complete` ends a turn; `session.usage` is only a live tick.
- Every request runs the full agent loop; restrict tools with `platform_toolsets.api_server`.

## Conversations and messages

### Message queue

Nothing is lost to a bad connection, and you don't have to wait for a reply to ask the next thing.
Both go through one outbox per conversation (`Conversation.outbox`, `Models/OutboxItem.swift`),
shown as dashed bubbles and saved with the conversation.

- **Offline.** If the server couldn't be reached and nothing of the reply arrived
  (`NetworkFailure.isConnectivity`), the question waits as "Waiting for connection" and retries on a
  5 / 15 / 30 / 60 s backoff, when the network comes back (`ConnectivityMonitor`), on foreground, and
  when you send something else, strictly in order. After an hour it asks for Send now. A connection
  dropped after the server had the request, and real server errors, still fail, because resending
  could repeat the turn.
- **During a reply.** Typing while a reply streams offers Steer and Send after this reply. Stop, or a
  failed turn, pauses the queue.
- **Voice.** A held spoken question is announced and ends the hands-free loop.

### Steering

While a Hermes turn streams, typing offers a steer button. The text is injected into the running
turn without cancelling it: `session.steer` on the Dashboard, `POST /v1/runs/{run_id}/steer` on the
API (the run id comes from `run.started`).

### Live thinking and interrupts

Replies show a "Thinking" section that streams reasoning and folds away when the reply lands, plus
tool chips. When the agent pauses a Dashboard turn, a card appears in the transcript and on the voice
screen: approvals (once / session / always / deny), clarifying questions, sudo (sent straight to the
gateway terminal, never stored) and secrets (saved on the gateway under the named env var).

### Subagents

Each child agent from `delegate_task` gets a row under the reply: goal, task N of M, live tool line,
then duration and summary. On the Dashboard, tap a row for the child's own transcript, and steer or
stop it (`subagent.*` events). The API stream doesn't forward subagent events, so rows there are
built from the delegate call's goals. `Views/SubagentRows.swift`.

### Attachments and sharing

The composer attaches photos (downscaled to 1600 px JPEG) and files (up to 8 MB):

| Connection | Images | Text files | PDF / other |
| --- | --- | --- | --- |
| Hermes Dashboard | `image.attach_bytes` | `file.attach` | `pdf.attach` / `file.attach` |
| Hermes API | `input_image` data URL parts | inlined into the prompt | refused (no file parts) |
| OpenAI-compatible | `image_url` parts (needs a vision model) | inlined | refused |

Bytes are stored one file per attachment under Application Support (file-protected); transcripts
keep metadata only. The share extension (`EchoShare`) writes to the App Group
(`group.com.goosehouse.echo`); the app turns shared items into a draft on its next foreground.

### Session list and housekeeping

On the Dashboard the list starts with **Projects** (`projects.tree`), grouped by working directory
and repo. Search, pin, rename, fork, archive and delete go through `PATCH /api/sessions/{id}`, fork
through `POST /api/sessions/{id}/fork` (API) or `session.branch` (Dashboard). Rows show token totals
and the gateway's cost estimate; long-press for the full usage breakdown. Any conversation exports
as Markdown. Local (OpenAI-compatible) conversations are saved on the phone as JSON with complete
file protection.

### Cron and Kanban

**Cron** lists the gateway's jobs: pause/resume, run now, recent runs, create (the gateway's own
schedule grammar), delivery targets, and blueprints on the Dashboard. Works over the Dashboard
(`/api/cron/jobs`) or the API (`/api/jobs`, no run history).

**Kanban** shows the Dashboard's task board plugin: one column at a time on the phone, swipe or menu
to move a card, edit, comment, and "Ask Redde about this card". Moving to Blocked or Scheduled asks
for a reason, Review or Done for a summary. It updates live over the plugin's events socket and
falls back to polling. `Services/HermesAutomation.swift`, `Views/CronView.swift`,
`Views/KanbanView.swift`.

## Rendering

Replies render as blocks: headings, lists, task lists, fenced code with highlighting and copy,
quotes, tables, images with a zoomable viewer. Mermaid fences and `$$ … $$` math render with bundled
mermaid.js and KaTeX in a sealed, self-sizing WebView (`Views/WebBlocks.swift`, `Resources/Web`), so
they work offline. Parser `Models/MarkdownBlocks.swift`, renderer `Views/MarkdownView.swift`,
highlighter `Services/SyntaxHighlighter.swift`.

Streaming text is buffered and applied about 20 times a second (flushed around tool events,
interrupts and the end of a turn). The transcript renders the newest 60 messages, with a button for
earlier ones. The footer's `ctx` is context occupancy: from the Dashboard's `context_used` /
`context_max`, or one call's tokens against the window on OpenAI-compatible servers; the Hermes API
only reports session totals, shown as `session N tok`.

## Voice

Tap the mic for voice mode. One button; the phase decides what a tap does (listen, stop, cancel,
barge in). A turn ends after about a second of silence; hands-free reopens the mic after each reply.
"Stop listening", "that's all", "goodbye" or "thanks" on its own ends the loop and is never sent.

Each turn's footer shows where the time went: end of speech → first spoken word (the number that
matters), recognizer finalize, time to first token, first token → audio, and total model time.

Replies are spoken sentence by sentence while they stream, by AVSpeechSynthesizer or a Kokoro server
("Server TTS"): one PCM streaming request per sentence, decoded ~100 ms at a time onto an
`AVAudioPlayerNode`, fetched ahead and played in order, with the built-in voice as the fallback. The
replay button speaks the last reply again without a new turn. The speech model is downloaded in the
background at launch.

**AirPods.** Full-bandwidth Bluetooth recording when the headset supports it; voice processing off
on headphones (on for the speaker and CarPlay). While the voice screen is open Redde is the Now
Playing app, so a stem press or play-pause does what the mic does. Removing the headset stops
speaking. "Announce on AirPods" makes alerts time-sensitive so Siri can read them.

**Background notifications.** Settings → Voice → "Notify me in the background": approvals,
questions, sudo and secret requests, finished replies and failures, as local notifications with
Approve / Deny and reply actions. A push relay (`companion/push-relay`) can deliver them when the app
isn't running.

## Siri, Shortcuts and controls

Two App Shortcuts, "Ask Redde" and "Talk with Redde" (hands-free); Siri also answers to "Hermes" and
"Sol". Siri only opens the app, which then listens with its own recognizer; long free-form questions
through Siri's dictation are unreliable. "Ask Redde a Question" in Shortcuts takes text and returns
the reply as text. The `EchoControls` extension provides Control Center, Lock Screen and Action Button
controls (via an App Group launch flag), Home Screen widgets (Last reply, Ask Redde) and the Live
Activity (`Services/TurnActivity.swift`).

### Siri AI (iOS 27, opt-in)

With "Let Siri use Redde" on, Redde adopts the iOS 27 App Schemas in the Messages domain: the agent
is the contact, each conversation a conversation, each turn a message. Siri can send a message and
speak the reply (waiting up to 20 s, `SiriTurn.replyBudget`), reply to an announced banner, draft,
edit, unsend, read, and find conversations (indexed in Spotlight, titles only when the app lock is
on). Messages go through the app's one `Conversation`, so they land in the transcript like typed
ones. Off means off: queries return nothing and Spotlight entries are deleted. Needs an iPhone that
runs Siri AI, English, and a supported region. `Intents/Siri/`, `Services/SiriIntegration.swift`,
tests in `EchoTests/SiriSchemaTests.swift`.

## CarPlay

A CarPlay scene in the voice-based conversational category (iOS 26.4+): **Ask Redde** and **Talk
with Redde** rows, then a voice-control card (Listening, Thinking, Speaking, Done). Replies are
spoken only. The brand lives in artwork drawn in code (`CarPlay/CarPlayArtwork.swift`), since
CarPlay owns layout and type. Declaring the scene enables multiple scenes, so the WindowGroup routes
external events to the existing window (`handlesExternalEvents` in `EchoApp`); re-check the Action
Button, Control Center and widget paths on a device after changes here.
`scripts/carplay-simulator.sh` previews the car screens in a separate, git-ignored simulator
project.

## App and settings

- **Themes:** seven (Messages, Paper, Slate, Terminal, Amber CRT, Hermes, Code), each with light and
  dark faces and the user's own accent and bubble colours. 13 app icons and 25 voice orbs.
- **iPad:** the session list is a `NavigationSplitView` sidebar; keyboard shortcuts (⌘N, ⌘K, ⌘1–3,
  ⌘L, ⌘↩, ⌘., ⌘⇧V, ⌘E, ⌘,; space and Esc on the voice screen).
- **App lock:** Face ID / Touch ID / passcode with a grace period; Siri, control and share requests
  wait until unlocked; background Shortcuts runs are protected by the Keychain instead.
- **Cloudflare Access:** a service-token ID and secret sent as `CF-Access-Client-Id` /
  `CF-Access-Client-Secret` on every Dashboard request and WebSocket handshake.
- **Transport security:** `NSAllowsArbitraryLoads` is set because users' servers often live on
  private networks without public certificates; HTTPS is used whenever the URL provides it.
- **First run:** no server is built in. The setup sheet takes a connection and credentials and tests
  them the way the transport will.

## Release notes for maintainers

- The App Store listing copy lives in `docs/app-store-listing.md`; the privacy policy and support
  page sources in `docs/`.
- `scripts/bump-build.sh` sets the build number; the version and build are in `project.yml`.
- `design/screenshots/capture.sh` and `compose.py` regenerate the App Store screenshots
  ([README](../design/screenshots/README.md)).
- Always install on devices with a clean build: incremental builds have shipped without the Siri
  phrase metadata.
