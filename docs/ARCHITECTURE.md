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

### Servers

Redde keeps a list of Hermes servers (Settings → Server, or the server row at the top of the
conversation list once there are two). One is active at a time.

- **Working copy.** The connection fields in `Settings` (both Hermes addresses, username, Cloudflare
  Access ID, model, provider, profile, and which Hermes connection) belong to the active server:
  editing them updates its `HermesServer` record, and `activateServer` loads another record into
  them, so the rest of the app reads `Settings` as before. The OpenAI-compatible connection, voice
  and appearance are app-wide.
- **Secrets per server.** The API key, Dashboard password, Cloudflare Access secret and per-profile
  keys are Keychain accounts named `<account>@<server id>`; `Keychain.read(.item)` resolves the
  active server from UserDefaults (`activeServerID`), so no read can happen before the scope is
  known. Removing a server deletes its accounts.
- **Switching** goes through `ServerSwitcher`, in one order: while Settings still describes the old
  server, the open conversation is saved (stamped with that server) and the Dashboard client drops
  its socket and the old server's cookies (cookies ignore ports, so two servers on one host would
  share one); then the new server loads. Lists key their loading on `Settings.connectionKey`
  (server + profile) and drop any answer that arrives after a switch; Cron and Kanban are rebuilt.
  The OpenAI-compatible connection belongs to no server, so switching servers doesn't leave it.
- **Saved conversations** carry their `serverID`; launch reopens the newest one from the active
  server. Untagged Hermes chats from before multi-server belong to the first server. The Shortcut
  keeps a session per server id and profile (`shortcutSessionID.<server>[.<profile>]`), cleared
  when its server is removed or everything is erased.
- **Records decode field by field** (`HermesServer.init(from:)`), so a list written by another
  version still loads. A list that can't be read at all is kept aside (`hermesServers.unreadable`)
  and the active server keeps its id, so the Keychain secrets filed under it still match.
- **Upgrading** from a single-server install: the existing setup becomes the first server, and its
  secrets move under it (`moveLegacySecretsToActiveServer`), each copied and read back before the
  old entry is deleted.

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

### Reply language

Settings → Voice → Reply language asks the agent to answer in one language (`Models/ReplyLanguage.swift`;
Automatic sends nothing). Each connection carries it differently: the Hermes API in the turn's
`instructions` (appended to the gateway's system prompt, next to Redde's client hint), the
OpenAI-compatible connection as a system message. The Dashboard's `prompt.submit` takes no
instructions, so a short note, "(Reply in Dutch (Nederlands).)", rides on the message; other
clients show it, and Redde strips it when history loads.

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

The composer's + menu attaches files (up to 8 MB), photos from the library, or a photo taken with
the camera (`CameraPicker`, a `UIImagePickerController` in a full-screen cover; hidden where there's
no camera). Images are downscaled to 1600 px JPEG:

| Connection | Images | Text files | PDF / other |
| --- | --- | --- | --- |
| Hermes Dashboard | `image.attach_bytes` | `file.attach` | `pdf.attach` / `file.attach` |
| Hermes API | `input_image` data URL parts | inlined into the prompt | refused (no file parts) |
| OpenAI-compatible | `image_url` parts (needs a vision model) | inlined | refused |

Bytes are stored one file per attachment under Application Support (file-protected); transcripts
keep metadata only. The share extension (`EchoShare`) writes to the App Group
(`group.com.goosehouse.echo`); the app turns shared items into a draft on its next foreground.

### Session list and housekeeping

On iPhone the list is a panel from the left (`SidePanel` in `Views/SwipeToOpen.swift`): a swipe to
the right anywhere on the chat pulls it out and it follows the finger (a UIKit pan that only starts
on a clearly sideways swipe, and gives way to a horizontal scroller that can scroll back, or to text
being edited or selected); tap the dimmed chat or drag it back to close. The panel stays built
between opens so it slides in without building a list, and "parks" once it has slid out: no width,
since UIKit's list, bar and segmented control inside ignore `accessibilityHidden` and VoiceOver
found them off screen. Parked, it hides its bar, drops the Kanban board (and its live socket), and
loads nothing; Chats and Cron refresh when it opens. On iPad the list is the split view's sidebar.
In both, the server switch and Chats / Cron / Kanban are the first row of each list, so they move
with pull-to-refresh.

On the Dashboard the list starts with **Projects** (`projects.tree`), grouped by working directory
and repo. Search, pin, rename, fork, archive and delete go through `PATCH /api/sessions/{id}`, fork
through `POST /api/sessions/{id}/fork` (API) or `session.branch` (Dashboard). Rows show token totals
and the gateway's cost estimate; long-press for the full usage breakdown. Any conversation exports
as Markdown. Local (OpenAI-compatible) conversations are saved on the phone as JSON with complete
file protection.

History from the Hermes API (`/api/sessions/{id}/messages`) is the gateway's database rows nearly
as-is, so `StoredMessage` decodes each field on its own: row ids are numbers, and one field of an
unexpected type once failed every transcript with "The data couldn't be read". A tool-call row folds
into the answer that follows it, as it looked live.

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

Streaming text is buffered and applied about 20 times a second, thinking on its own 5 times
(flushed around tool events, interrupts and the end of a turn). The transcript renders the newest 60
messages, with a button for earlier ones, and lays all of them out, so what a screen update costs
grows with the conversation. Three rules keep a streaming reply cheap:

- Nothing outside the transcript reads `Conversation.messages` in a view body. Every update
  rewrites that array, and the header doing so rebuilt the navigation toolbar, the conversation
  list and the composer each time. The header reads `title` and `hasMessages`, which the
  conversation keeps as their own observed values.
- Nothing in a row animates through SwiftUI while a reply runs. Each animated frame walks the
  whole page's view tree; the waiting waveform, at 30 frames a second, took a third of a core in a
  long conversation. It is a `UIView` whose bars Core Animation moves (`WaveformBarsView`).
- A mid-stream update costs about the same whether it adds one token or twenty, so the cadence
  is the lever.

Measured in the simulator with a 32-exchange conversation (about 340,000 characters): a silent wait
went from 35% of a core to 3%, streamed thinking from 55% to 20%. Reply text is still about 37%, and
that conversation holds 1.4 GB; both come from laying out the whole page, which is the next thing
to bound.

The footer's `ctx` is context occupancy: from the Dashboard's `context_used` /
`context_max`, or one call's tokens against the window on OpenAI-compatible servers; the Hermes API
only reports session totals, shown as `session N tok`.

## Voice

The waveform button beside the message field opens voice mode (or the Action Button, Siri, Control
Center, or launch with "Open to the voice screen"). One button on the voice screen; the phase
decides what a tap does (listen, stop, cancel, barge in). "New conversation in voice mode" starts a
fresh conversation each time the voice screen opens, before it appears, and also while the last
conversation is still loading at a cold launch. A turn ends after about a second of silence; hands-free reopens the mic after each reply.
"Stop listening", "that's all", "goodbye" or "thanks" on its own ends the loop and is never sent.

Each turn's footer shows where the time went: end of speech → first spoken word (the number that
matters), recognizer finalize, time to first token, first token → audio, and total model time.

Replies are spoken sentence by sentence while they stream, by AVSpeechSynthesizer or a Kokoro server
("Server TTS"): one PCM streaming request per sentence, decoded ~100 ms at a time onto an
`AVAudioPlayerNode`, fetched ahead and played in order, with the built-in voice as the fallback. The
replay button speaks the last reply again without a new turn. The speech model is downloaded in the
background at launch.

**Languages.** Settings → Voice → Listening language picks what `SpeechTranscriber` listens for
(default: the iPhone's language); picking one reserves and downloads its model, releasing the
oldest reserved language only when the app's limit is reached. "Voice for replies: Match each reply"
detects each reply's language on-device (`SpokenLanguage`, NaturalLanguage) from its first
sentences: leaving the listening language takes 40+ characters at 90% confidence (short Chinese,
Japanese and Korean pass sooner), and after 400 characters it gives up. The best installed Apple
voice for that language reads it (the listening dialect, else the region's, else a home dialect
such as en-US or pt-BR); on Kokoro, a voice in that language of the same gender, or the Apple voice
for the whole reply when Kokoro has none (Dutch, German, …). Only Kokoro's `<lang><f|m>_` ids carry
a language. "Always <listening language>" reads everything in one voice.

**Spoken prefixes.** Settings → Voice → Spoken prefixes (`Services/Voice/VoiceRouting.swift`,
`Views/SpokenPrefixesView.swift`; rules JSON in `Settings.spokenPrefixes`, off by default). A rule
is a word, aliases, an optional text prefix and an optional model. `VoiceRouting.route` matches a
leading word (a "hey / ok" lead-in and trailing punctuation allowed), strips it, puts the prefix in
front, and names the model; the first matching rule wins. It runs in exactly two places: the final
endpointed utterance in `VoiceSession.handleUtterance` and Siri's message intent. The composer,
including dictation into it, is never touched. A model switch goes through
`Conversation.switchModel`: the setting moves and an open hermes session is re-pinned
(`pinOpenSessionModel`, shared with the model picker), so it's sticky. When rules exist the
recogniser gets the words as `AnalysisContext` contextual strings.

**Model and provider.** A pick is a model plus the provider slug the host listed it under, and the
slug is only a memory of that list. Before it is used for a new conversation or a switch,
`Conversation.liveProvider` checks it against the host's current list (`model.options`, three
seconds at most): a provider that is gone follows the model to one that lists it, a named endpoint
is preferred over the bare `custom` bucket, and a pick without a provider gets one. How it is sent
differs by connection. The Dashboard takes it at `session.create`, and a live switch is a `/model`
line with `--provider` (`HermesServeClient.modelSwitchValue`); a bare model name there is
re-resolved under the session's `custom` bucket and can leave the endpoint. The Hermes API takes
`model`, `provider` and `require_model_lock` on every turn: without the lock the gateway runs the
session's stored model on its *default* provider. Hermes before 0.21.4 ends such a turn with a
"lock runtime mismatch" between the endpoint's name and its `custom` bucket after the reply is
complete and stored; `HermesSessionsTransport.isLockBucketMismatch` lets that one through.

**Earpiece.** The proximity sensor is watched only while a reply is spoken (it blanks the screen
whenever anything is near), and it reads "not near" whenever it's off or has just come on. So the
route follows the last real reading between replies, and a settle check after it comes on catches a
phone put down meanwhile.

**AirPods.** Full-bandwidth Bluetooth recording when the headset supports it; voice processing off
on headphones (on for the speaker and CarPlay). While the voice screen is open Redde is the Now
Playing app, so a stem press or play-pause does what the mic does. Removing the headset stops
speaking. "Announce on AirPods" makes alerts time-sensitive so Siri can read them.

**Replies that outlast the screen.** A reply started in the app keeps streaming after the phone
locks or the app is left (`Services/BackgroundTurn.swift`). Each such turn is submitted as an iOS
26 continued-processing task (`BGContinuedProcessingTaskRequest`, one identifier per turn under
`com.goosehouse.echo.turn.*`, background mode `processing`): iOS shows its own activity with a
progress bar and a stop button, and the process keeps its network connection. A reply has no known
length and iOS expires a task whose progress stalls, so the bar creeps toward the end and only gets
there with the turn. iOS can refuse the task or end it early, a turn started from the background
(Siri, a notification button) can't have one, and neither can the simulator or a Mac; then the
older 30-second background task is all there is. When the time is taken back the turn is not
cancelled: on a Hermes connection the agent keeps working and the Dashboard picks the reply up on
return, while a direct model connection reports that it was stopped. Measured on an iPhone on
iOS 27 with a 100-second reply and the app in the background: complete with the task, suspended
after 33 seconds without it.

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
project. The `audio` background mode keeps a conversation going when the car screen switches to
navigation (or the phone locks): without it iOS cuts the microphone and silences the reply as soon
as Redde leaves the foreground, and the continued-processing task (above) only covers the wait in
between. Untested in a car as of 2026-10-02. The flip side: a mic left open on a locked phone
would now stay open, so when every scene goes to the background while listening, the session
stops (`VoiceSession.leftForeground`) unless hands-free is on or the car is connected
(`CarPlaySceneDelegate.isConnected`). A reply being thought about or spoken is never stopped there.

## App and settings

- **Themes:** seven (Messages, Paper, Slate, Terminal, Amber CRT, Hermes, Code), each with light and
  dark faces and the user's own accent and bubble colours. 13 app icons and 25 voice orbs.
- **Model:** per-connection model and reasoning effort (Default, None, Low, Medium, High, and
  X-High / Max for frontier models; None on a fresh install). The level follows the phone, not the
  session: it goes with every fast-lane and Hermes API turn, with every new Dashboard session,
  and is re-pinned through `config.set key=reasoning` when a Dashboard session is resumed or the
  picker changes. A typed `/reasoning <level>` takes the same route, since `slash.exec` only
  changes the host's slash worker. On the fast lane any level turns thinking on and travels as
  `reasoning_effort` (top-level, and as a chat-template kwarg on self-hosted endpoints); None
  turns thinking off through the kwarg alone.
- **iPhone:** the session list is a side panel (see Session list).
- **iPad:** the session list is a `NavigationSplitView` sidebar; keyboard shortcuts (⌘N, ⌘K, ⌘1–3,
  ⌘L, ⌘↩, ⌘., ⌘⇧V, ⌘E, ⌘,; space and Esc on the voice screen).
- **App lock:** Face ID / Touch ID / passcode with a grace period; Siri, control and share requests
  wait until unlocked; background Shortcuts runs are protected by the Keychain instead.
- **Cloudflare Access:** a service-token ID and secret sent as `CF-Access-Client-Id` /
  `CF-Access-Client-Secret` on every Dashboard request and WebSocket handshake.
- **Transport security:** `NSAllowsArbitraryLoads` is set because users' servers often live on
  private networks without public certificates; HTTPS is used whenever the URL provides it.
- **What's New:** after an update, the first launch shows that version's highlights once
  (`Models/WhatsNew.swift`, one entry per version worth announcing); fresh installs, launches into
  voice mode, behind the lock or from Siri skip it. Settings → About reopens it.
- **First run:** no server is built in. The setup sheet takes a connection and credentials and tests
  them the way the transport will.

## Release notes for maintainers

- The App Store listing copy lives in `docs/app-store-listing.md`; the privacy policy and support
  page sources in `docs/`.
- `scripts/bump-build.sh` adds one to the build number (not the commit count: the public history
  restarted below builds already uploaded); the version and build are in `project.yml`.
- `scripts/hermes-lab/lab.sh run` checks that a picked model reaches its endpoint on unmodified
  Hermes releases, over both connections and five provider setups
  ([README](../scripts/hermes-lab/README.md)). Run it after touching how models or providers are
  sent, and when Hermes ships a release.
- `design/screenshots/capture.sh` and `compose.py` regenerate the App Store screenshots
  ([README](../design/screenshots/README.md)).
- Always install on devices with a clean build: incremental builds have shipped without the Siri
  phrase metadata.
