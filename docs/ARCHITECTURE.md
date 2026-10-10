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
| Hermes Dashboard | `hermes serve`, `ws://…:9119/api/ws` | Dashboard username + password (cookie login), or a browser sign-in (bearer tokens); then a 30 s WebSocket ticket | The desktop-gateway protocol: JSON-RPC over one WebSocket. Live `reasoning.delta`, tool events, approvals, and slash commands (`slash.exec` / `command.dispatch`) |
| Hermes API | The gateway's API server, `https://…:8642/api/sessions/{id}/chat/stream` | Bearer `API_SERVER_KEY` | The shared session ledger: every gateway session from Telegram, Discord, the CLI and Redde, resumable from the list. Streams reasoning (`tool.progress` with `_thinking`), tool starts and results, and usage |
| OpenAI-compatible | `…/v1/chat/completions` (llama.cpp, llama-swap, vLLM, Ollama, a provider) | Optional API key | Straight to a model, no agent: no tools, lowest latency, works when the gateway is down. History is sent each turn and never rewritten, so a llama.cpp prefix cache stays warm |

Both Hermes connections write to the same `state.db`, so a session started by voice shows up in the
dashboard and in Telegram's `/sessions`, and any of theirs can be continued here. Memory saves and
other writes are agent-side tools: say "remember that…" and watch the tool chip.

Screens ask `SessionBackend` for the current backend instead of branching on the connection.

### Signing in to the Dashboard through a browser

A Dashboard that signs people in with Google or another identity provider (Hermes's `self_hosted`
OIDC plugin, Nous Portal) has no password to give the app. There the person taps **Sign in with a
browser** (Settings → Connection details, and first-run setup), and the app does OAuth for native
apps (RFC 8252) with PKCE against the Dashboard's own routes, which Hermes has had since 0.21 and
announces in `/api/status` as `auth_flows: native_pkce` (`Services/DashboardSignIn.swift`):

1. A listener opens on the phone's loopback interface, on a port the system picks
   (`LoopbackCallback`). Hermes takes no other kind of return address: `http://127.0.0.1:<port>/…`
   only, so a custom URL scheme can't stand in.
2. A system sign-in sheet (`ASWebAuthenticationSession`) opens
   `/auth/native/authorize?code_challenge=…&redirect_uri=http://127.0.0.1:<port>/callback&state=…`.
   The Dashboard hands the browser on to whatever it signs people in with; with a password login
   that is its own `/login` page. The app sees none of it.
3. The Dashboard sends the browser to the loopback address with a one-time code. The listener
   answers only the request that carries this sign-in's `state`, takes the code, and redirects to
   `redde-signin://done`, which closes the sheet.
4. `POST /auth/native/token` with the code and the PKCE verifier (which never left the app) returns
   an access token, a refresh token and `expires_at`. They go into the Keychain, per server
   (`serve-sign-in@<server id>`).

From then on `HermesServeClient` sends `Authorization: Bearer` with every REST request and when it
buys a WebSocket ticket, and never logs in with a password while tokens are stored. A token within
a minute of lapsing is traded in first (`/auth/native/refresh`), and so is one the server answers
with 401. A refresh token is good for one use, so however many requests ask at once share one
refresh, and the pair that comes back replaces the stored one. A refresh the server refuses
signs the phone out ("sign in again"); one that fails because the identity provider is down
changes nothing. Tokens aren't put in setup codes and aren't handed to the watch: another device
signs in itself. `scripts/hermes-lab/lab.sh signin` runs the whole exchange against each Hermes
release, with a test standing in for the person in the browser.

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

### The gateway itself

Settings → Gateway is the Hermes server as its own Dashboard administers it (`GatewayAdmin.swift`,
`GatewayModel.swift`, `GatewayView.swift`). All of it is the Dashboard's REST API, the routes its
own web pages use, and the same in Hermes 0.21.0, 0.21.3 and 0.21.5; the Hermes API server has
none of them, so the screen takes the Dashboard login.

| What | Route |
|---|---|
| Version, whether the gateway runs, what it is connected to, what is out of order | `GET /api/status` |
| The machine: name, system, uptime, memory and disk in use | `GET /api/system/stats` |
| MCP servers, a switch for each, and a test | `GET /api/mcp/servers`, `PUT …/{name}/enabled`, `POST …/{name}/test` |
| Logs: agent, errors, gateway; by level and by search | `GET /api/logs` |
| Restart the gateway | `POST /api/gateway/restart`, then `GET /api/actions/gateway-restart/status` |
| Check for an update, and apply it | `GET /api/hermes/update/check`, `POST /api/hermes/update`, then `GET /api/actions/hermes-update/status` |

The selected profile rides on the routes that take one (`HermesServeClient.profilePlacement`):
status, MCP servers, logs and the restart. A switch changes Hermes's config, which Hermes reads
for the next conversation, so the screen says "takes effect in new conversations". A server that
a plugin provides (0.21.5) has no switch: Hermes refuses to change it.

A restart and an update are asked for, confirmed with what they will stop, and then followed
(`GatewayModel.follow`): Hermes runs them as background commands and reports whether each is
still running and what it has printed.

- **A restart is over** when its command has ended, or when a gateway that started after the
  request is running (`memory.boot_id` in the status is the gateway's start time). The second is
  for a gateway that was started by hand: with no service manager, Hermes 0.21.0 and 0.21.3 stop
  the old gateway and run the new one inside the restart command, which therefore never ends.
  Hermes 0.21.5 stops such a gateway, takes the one it just stopped for a running one and starts
  nothing; the screen then says the gateway hasn't come back, and what to run on the server.
- **An update** restarts Hermes on the way, the Dashboard included, so for a while nothing
  answers; that is waited through, up to fifteen minutes. Afterwards Hermes may no longer know
  how the command ended, so the version before and after is what decides. Where Hermes is updated
  some other way (a container, a package manager) it says so and names the command, and nothing
  is started.
- There is no Start button. Hermes's own start installs a launchd or systemd service on the
  machine if there is none, which is more than a phone should decide; the message names the
  command instead.

`-echo.demoGateway` shows the screen on sample data (`DemoGateway`), which is what
`EchoUITests/GatewayUITests` walks. `scripts/hermes-lab/lab.sh admin` runs the client and the
model against each release.

### The server's files

Settings → Files is the Hermes host's folders, through the Dashboard's own file manager
(`ServerFiles.swift`, `ServerFilesModel.swift`, `FilesView.swift`). The routes are the same in
Hermes 0.21.0, 0.21.3 and 0.21.5, and like the Gateway screen it takes the Dashboard login.

| What | Route |
|---|---|
| A folder: what is in it, its parent, whether the server keeps to one folder | `GET /api/files?path=` |
| A file, saved to the phone | `GET /api/files/download?path=` |
| A file from the phone | `POST /api/files/upload-stream` (a multipart form) |
| A new folder | `POST /api/files/mkdir` |
| Delete a file, or a folder with everything in it | `DELETE /api/files` |
| A text file read for the editor, and saved back | `GET /api/fs/read-text`, `POST /api/fs/write-text` |

- **Where it starts** is the server's choice: its user's home, or the one folder a hosted install
  (or `HERMES_DASHBOARD_FILES_ROOT`) keeps the file manager to, in which case nothing above it
  opens and the screen offers no "Go to Folder". Otherwise the first page has a link to the
  Hermes home of the profile in use, which is a dot folder and would be hidden with the rest.
- **Hermes keeps credentials out**: `.env`, `auth.json`, `config.yaml`, the token folders. They
  are not listed, and asking for one is refused; the screen says so.
- **Transfers go by file, not through memory.** A download is saved by the URL session and moved
  to a folder of its own under the temporary directory, under its own name, for Quick Look, whose
  share button is the way to keep it or send it on; those copies are thrown away when the browser
  is next opened. An upload's form is written to a file first, the source copied through in
  pieces, and sent from there. Hermes takes and gives at most 100 MB as one file; a larger one
  isn't sent or asked for.
- **An upload never replaces unasked.** A name already in the folder is held back and asked
  about; only a yes sends it with `overwrite`.
- **Text opens in an editor** when its type or its ending says text and it is no larger than the
  512 KB Hermes reads for one. Hermes says when what it read was cut short or isn't text after
  all; then it can be read and not saved, since saving would cut the file short.
- A "+" in a name is sent as `%2B`: in a query the server reads a bare one as a space.

`scripts/hermes-lab/lab.sh files` drives the client against each release inside a scratch folder
of its own: a file up, listed and down byte for byte, a refusal to replace, text read and saved,
three megabytes both ways, a credentials file neither listed nor handed out, and a folder deleted
with what was in it. `-echo.demoFiles` shows the screen on sample folders for
`EchoUITests/FilesUITests`.

### Servers

Redde keeps a list of Hermes servers (Settings → Server, or the server row at the top of the
conversation list once there are two). One is active at a time.

- **Working copy.** The connection fields in `Settings` (both Hermes addresses, username, Cloudflare
  Access ID, model, provider, profile, and which Hermes connection) belong to the active server:
  editing them updates its `HermesServer` record, and `activateServer` loads another record into
  them, so the rest of the app reads `Settings` as before. The OpenAI-compatible connection, voice
  and appearance are app-wide.
- **Secrets per server.** The API key, Dashboard password or sign-in, Cloudflare Access secret,
  custom headers and per-profile keys are Keychain accounts named `<account>@<server id>`; `Keychain.read(.item)` resolves the
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

### Setup codes

A connection can arrive as a link, `https://redde.goosehouse.org/connect#…` or
`redde://connect?…`, or as a QR code of it (`SetupCode`; the parameters are in the README). There
are three ways in: the link is opened (the Camera, a tap), scanned in Setup (`SetupCodeScanner`,
VisionKit's `DataScannerViewController`, hidden where the device can't scan), or pasted there (a
`PasteButton`, so no clipboard prompt). All three end in `SetupCodeSheet`.

- **A link is untrusted input.** Nothing is applied on arrival: the sheet shows every address in
  full and which one the app will talk to, and saves on the button. An address must be http or
  https with a host and no user name in it ("http://my-server@elsewhere" reads like the wrong
  host); a code from a newer format version is refused whole.
- **A code is only ever combined with secrets it brought itself** (`SetupCodeInstaller`). It fills
  in the active server only when nothing at all is stored for that one in the Keychain, so it has
  never connected (a first run, a server just added); every field is replaced, so nothing typed
  there earlier is mixed in. Otherwise it becomes a new server and the app switches to it through
  `ServerSwitcher`. The OpenAI-compatible endpoint is the app's, not a server's, so a code replaces
  it, and when the address changes the old key is deleted unless the code carries one: a link must
  not be able to point a saved key at another host.
- **Then it is tested** (`ConnectionTester.current`) and the sheet says how that went. A server
  that was added and doesn't answer can be taken back out: `install` returns a receipt and
  `remove` restores the server, connection and endpoint from before.
- **A link opened from outside** goes through `LaunchRouter`, like a Siri request: it waits for
  the app lock, and whatever sheet is up (first-run setup included) closes first, because a second
  sheet can't present over one. A first run the code didn't finish goes back to setup.
- **Making one.** `SetupCode(server:settings:secrets:)` builds a server's code, shown as a QR code
  (`QRCode`, Core Image) by Settings → Connection → Set up another device for the active server,
  and from a server's touch-and-hold menu for the others. The OpenAI-compatible endpoint goes
  along when there is one. Secrets are left out until asked for, behind device authentication, as
  showing a saved password is anywhere on iOS; a link copied with secrets leaves the clipboard
  after two minutes. `scripts/setup-code.py` makes a code on the server, for the first device.
- **Two forms of the link.** What the app hands out is the web form, a universal link: the app
  claims `applinks:redde.goosehouse.org` (Associated Domains) and the site names the app for
  `/connect` in `.well-known/apple-app-site-association`, so iOS opens the link in Redde wherever
  it is tapped and no other app can take it. The parameters ride in the fragment, which a browser
  never sends, so the site doesn't see a connection; only the fragment is read, and parameters
  after a `?` are refused. Where the app isn't installed, the page
  (`companion/website/public/connect.*`) shows what the link carries, offers the App Store, and
  hands the same parameters to the app's own form, `redde://connect?…`: a link tapped on its own
  page never opens an app, so that form is the page's way in, and it is also the form that
  involves no website. The page takes the fragment out of the address bar at once, renders it as
  text only, and is served with a content security policy that allows no connections. Both forms
  arrive through `onOpenURL` (or as a web-browsing activity); `LaunchRouter` drops the second of
  a pair. `echo` stays the scheme for the app's own links.

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
- **Siri and Shortcuts** can open voice mode on a named profile: "Ask Work in Redde"
  (`AskProfileIntent`, with its phrases in `EchoShortcuts`). Siri learns a phrase for each profile
  it is given, so the phone keeps the ones it knows of (`ProfileCatalog`, per server): what the
  Dashboard listed last, or over the Hermes API, which has no list, the names that were chosen by
  hand (those show in the picker from then on, and can be swiped off). Siri and Shortcuts ask
  through `ProfileCatalog.refreshed`, which asks the Dashboard again when there is a login and it
  answers within four seconds. The action only leaves a request with the profile on it
  (`LaunchRouter.requestVoice(handsFree:profile:)`); the app moves to the profile where it takes
  the request up, in front and past the app lock, and a name it doesn't know changes nothing.
  `EchoShortcuts.updateAppShortcutParameters()` runs whenever the kept list or the server
  changes. Siri's phrases are trained at build time: a clean build, as for the other two.

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
- On the Dashboard, `message.complete` ends a turn; `session.usage` is only a live tick. A
  `session.info` with `running: false` ends one too (a turn stopped from elsewhere sends no last
  message), but only a turn that was seen running: Hermes 0.21.3 and 0.21.5 send that info once
  more some 75 ms after a reply's last message, by when a message that waited in the outbox is
  already listening for its own reply.
- Every request runs the full agent loop; restrict tools with `platform_toolsets.api_server`.

## Conversations and messages

A conversation is titled by its first question (60 characters), or by its name once it has one
(`Conversation.name`, saved in the record). When a new one gets its title, the header's "New
conversation" lifts away and the title types itself in behind a caret (`Views/TypedTitle.swift`);
opening another conversation just shows its title, and so does Reduce Motion.

A name comes from Rename in the header's ••• menu (Save, or Return on the keyboard), which for a
gateway session renames it on the gateway first so the list, the Dashboard and the header agree
(titles there must be unique, so the gateway can refuse; the alert says why). It also comes from
the gateway: a session opened from the list brings its title, and the open session's title is
read again whenever the list loads (`noteServerTitles`), which picks up a rename made in the list
or the Dashboard and the title Hermes gives a session by itself. The title Redde gives a new API
session, the question and a timestamp, is not a name (`Conversation.name(fromServerTitle:)`). An
empty name takes a conversation kept on the phone back to its first question.

### Start screen

An empty conversation shows the app's mark, a greeting for the time of day, and up to three cards,
each one tap (`Views/StartScreen.swift`, `Services/StartCards.swift`). The pieces come in one after
another. They sit above the middle of the screen, a third of the spare room over them and two
thirds under: dead centre read as low, with the title above and the message field at the bottom.

- **Calendar:** once Redde has calendar access, the next event today or tomorrow, read on the
  phone; tapping asks about that day with its events attached. Before access was ever asked, the
  card offers "What's on my calendar today?" and the tap asks for it. Refused, there is no card.
  The screen never asks on its own.
- **Continue:** the most recent other conversation on the phone.
- **Home:** when the gateway's toolsets include Home Assistant, switched on and set up. Asked of
  the gateway once per connection, and never on the OpenAI-compatible connection, which has no
  tools.

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

While a reply is being made, a dot pulses beside the agent's name (`LiveMark`). As its text
arrives, the newest characters are drawn faint, a little low and, at the very end, blurred, with
a dot after the last one, so words come up rather than appear in blocks (`StreamingTail`, a
`TextRenderer` on the last block's text; in a list, on the item being written). When the reply
finishes, that edge fades into plain text and the actions fade in.

What went into a reply sits above it as a pair of folds in one style (`MessageRow.foldHeader`,
`FoldBody`): a chevron and a quiet line, opening onto its content behind a rule down the left.

- **Thinking:** while the model thinks, "Thinking" with a light passing over it (`ShimmerText`)
  and the tail of the reasoning underneath; when the reply lands it folds to "Thought for 6 s"
  (the message keeps `reasoningStartedAt`/`reasoningEndedAt`; older replies say "Thought") and
  opens onto all of it. The speaker line's "is working · 7 s" shimmers the same way for the whole
  turn.
- **Tools:** "Working · 2 tools" while they run, with a step per tool whose spinner becomes a
  check that draws itself (`StepMark`); then "Used 2 tools · 2.1 s", from
  `ToolActivity.startedAt`/`endedAt`. Open until the reply starts writing, folded after; saved
  replies show it folded.

A step opens onto what the tool was called with and what it returned (`ToolActivity.args` and
`output`, text cut to 12,000 characters each; `MessageRow.stepDetail`), with Copy and the whole
text in a sheet. Where that comes from depends on the connection:

| | The call | The result |
| --- | --- | --- |
| Dashboard, live | `tool.start` → `args` | `tool.complete` → `result` (or `result_text`) |
| Dashboard, reopened | the history row's `args` | only for the edit tools (`content`) |
| Hermes API, live | `tool.started` → `args` | not on the stream: `tool.completed` names the tool and nothing else |
| Hermes API, reopened | the assistant row's `tool_calls[].function.arguments` | the `tool` row after it |

So a step opened without its result asks for it once (`Conversation.loadToolDetails`): the
stored transcript, `GET /api/sessions/{id}/messages`, mapped by `mapStored` and matched to the
reply by its tools and text. That needs the Hermes API's address and key and a server session; a
Dashboard conversation can use it too, since both write one ledger. Without them the step says no
output was kept.

A reply's actions (copy, read aloud, regenerate, more, and the timings) sit under every finished
reply. Copy turns into a check for a moment, ticks, and says "Copied" in the transcript's toast
(`Toaster`, an object in the environment rather than a closure: a closure there would invalidate
every row on each update).

When the agent pauses a Dashboard turn, a card appears in the transcript and
on the voice screen: approvals (once / session / always / deny), clarifying questions, sudo (sent
straight to the gateway terminal, never stored) and secrets (saved on the gateway under the named
env var). Hermes asks in one of two ways, and the client speaks both (`HermesServeClient.prompt`):
0.21.0 sends a `<kind>.request` notification answered by a `<kind>.respond` call; 0.21.3 and later
send a JSON-RPC request to the client, answered by the response frame with its id, and from
0.21.5 only to a client that has said `client.capabilities {server_requests: true}`. A client that
doesn't say so is never asked and the command is refused, which is what Redde 1.5 and 1.6 (259) do
on those releases. `scripts/hermes-lab/lab.sh approvals` checks every release.

### Follow-ups and context chips

Two kinds of suggestion around the composer, both optional:

- **Follow-up questions** (Settings → Voice, off by default): once a reply finishes, three things
  the user might ask next appear as chips above the field and send on tap (`FollowUpChips`,
  `Conversation.followUps`). They are written by the OpenAI-compatible connection's model in one
  plain, non-streaming completion (`Services/FollowUps.swift`), whatever connection the
  conversation is on: the agent's own session can't be asked without the question landing in the
  transcript. So the setting needs that address; without it the toggle is disabled. Cleared by
  the next send, a cancel, or opening another conversation.
- **Context chips** (`Services/ComposerContext.swift`): what the draft mentions that the phone can
  attach. A day ("tomorrow at 9", "Oct 24", found by `NSDataDetector`) offers "Calendar · Sun,
  Oct 4"; tapping reads that day's events with EventKit (full-access permission, asked on the
  first tap) and attaches them as a text file, which inlines into the prompt on the API and the
  fast lane and goes up as a file on the Dashboard. A file name from a recent conversation's
  attachments offers "Attach plan.md". Chips can be dismissed for the draft; nothing is read until
  tapped.

### Subagents

Each child agent from `delegate_task` gets a row under the reply: goal, task N of M, live tool line,
then duration and summary. On the Dashboard, tap a row for the child's own transcript, and steer or
stop it (`subagent.*` events). The API stream doesn't forward subagent events, so rows there are
built from the delegate call's goals. `Views/SubagentRows.swift`.

### The agent's task list

Hermes's to-do tool (`todo_list`; `todo` before 0.21.3) is the agent's own plan for a long job.
A reply that touched it shows the list as a checklist under its steps (`Views/TodoChecklist.swift`):
done, in progress, still to do, dropped, subtasks indented, "2 of 5 done". Each reply keeps the
list as it left it (`Message.todos`), so scrolling back shows how the plan went.

Hermes keeps the list; the app only reads it, from whichever source the connection has
(`Models/TodoList.swift`):

- **Dashboard, live.** The host says what the whole list is after every change (`todo.updated`,
  in 0.21.0, 0.21.3 and 0.21.5 alike), and that is taken as it comes (`TurnEvent.todos`).
- **Hermes API, live.** The stream names a finished call with what it wrote and without the
  tool's answer. A call that replaces the list names all of it; one that merges names what
  changed, and is applied to the list before it the way Hermes's own store does. When the turn is
  over the transcript's end is read once for the answer itself (`answeredTodos`), which then is
  the list.
- **A transcript read back**, from either connection or from disk: the calls are replayed in
  order (`TodoList.resolve`), each by its answer where the row kept one. On the Dashboard the
  newest list is then set against the host's own (`todo_state` in `session.resume`).

Things about Hermes this had to allow for, all measured in the lab:

- From 0.21.3 the model reaches most tools through `tool_call`, which names the tool and carries
  its arguments. Live events name the inner tool; stored transcripts keep `tool_call`. Steps are
  unwrapped to the tool they called everywhere (`ToolActivity.unwrapped`), not only for the list.
- `tool_call` checks arguments and turns a call down without running the tool (a merge whose item
  has no `content`, for one). The answer says "NOT invoked", and such a call changes nothing.
- The Dashboard's history lists a tool row before the reply's row when the model called a tool
  without saying anything first; those rows are held and given to the reply that follows.
- Over the Hermes API, 0.21.3 and 0.21.5 start each turn on an empty list: the agent is built
  anew for every message, and what should restore its list from history still looks for a call
  named `todo`. A merge in a later turn therefore leaves only the items it named, and that is
  what the tool answers and what the app shows. The Dashboard keeps its agent, and the list.

`scripts/hermes-lab/lab.sh todos` checks all of it with the app's own client on the three
releases. `-echo.demoTodos` seeds a conversation with a list for `EchoUITests/TodoChecklistUITests`.

### Attachments and sharing

The composer's round button follows what you're doing (the app's waveform, still, for voice; send;
stop; steer and queue during a reply) and springs between those; the field gets a faint accent
ring while there is something to send. The + menu attaches files (up to 8 MB), photos and videos from the library, or a photo taken with
the camera (`CameraPicker`, a `UIImagePickerController` in a full-screen cover; hidden where there's
no camera). Images are downscaled to 2560 px JPEG:

| Connection | Images | Text files | PDF / video / other |
| --- | --- | --- | --- |
| Hermes Dashboard | `image.attach_bytes` | `file.attach` | `pdf.attach` / `file.attach` |
| Hermes API | `input_image` data URL parts | inlined into the prompt | refused (no file parts) |
| OpenAI-compatible | `image_url` parts (needs a vision model) | inlined | refused |

`file.attach` only puts the file in the session's workspace and answers with a reference to it
(`@file:attachments/notes.txt`). Nothing ties it to the next message: the agent learns of the
file only if the message names it, so the references are added to what is submitted
(`HermesServeTransport.prompt`). Hermes then inlines a text file where the reference stands and
names any other by path and type. Until 2026-10-07 the reference was dropped and such files
never reached the agent; `lab.sh approvals` now attaches one of each kind on every release.

A video (from Photos or Files) is a file like any other to the server; the app shows its first
frame under a play mark (`VideoPoster`) and plays it in Quick Look. One over the 8 MB limit is re-encoded, at medium quality
and then at low, and refused only if it is still too big (`Attachment.video`).

Bytes are stored one file per attachment under Application Support (file-protected); transcripts
keep metadata only. The share extension (`EchoShare`) writes to the App Group
(`group.com.goosehouse.echo`); the app turns shared items into a draft on its next foreground.

A drop anywhere on the chat goes to the composer too (`DroppedItems` sorts it, `ChatDropTarget`
is the modifier on the chat): pictures and files join what is waiting to be sent, a link or a
dragged selection goes on the end of the draft. A text file out of Files and a sentence out of a
web page can register the same types; what tells them apart is whether a file stands behind the
item, so one is attached and the other typed. The providers' callbacks come on queues of their
own and are made in nonisolated helpers for that reason. `-echo.dropHint` shows the outline a
drag brings up, since the simulator can't drag between apps.

"Select text" in a reply's menu opens a plain copy of it that selects by the word
(`SelectableTextSheet`, a `UITextView`: SwiftUI's selectable `Text` has no say in the selection's
menu). In the transcript that menu starts with "Ask about this", which closes the sheet and puts
the selection in the composer as a Markdown quote with room for the question (`Quote`), through
the same hand-over Siri's "draft a message" uses (`LaunchRouter.requestDraft`).

### Writing a message

- **A draft per conversation** (`Services/Drafts.swift`). What is typed and not sent stays with
  its conversation, and its text is on disk (`drafts.json`, protected like the transcripts), so
  it is there after the app has been closed. `ContentView.bindDraft` swaps the composer's text
  when another conversation opens. A conversation with nothing said has no lasting identity, so
  every new one shares one draft, which stays with it when its first message makes it a chat.
  Attachments waiting in a draft are kept for the run only: their bytes belong to no transcript
  yet. "Edit & resend" borrows the field and gives back what was there. Erase everything
  removes the drafts too. The conversation list marks a row that has one ("Draft"): `Drafts`
  is observable in that one respect, which conversations have a draft, so the list is redrawn
  when a draft begins or ends and not with every key.
- **Return** (Settings → Writing). SwiftUI's multi-line field always starts a new line on
  Return. Set to send, the composer takes a draft that grew by exactly one line break for a
  Return (`ComposerView.isReturn`), takes the break out and sends; on a keyboard Return sends
  and Shift-Return is the line break (`onKeyPress`).
- **A page of its own.** Past 160 characters or three line breaks a button in the field opens
  the draft in `ComposerEditor`, a `TextEditor` on a sheet, where Return is always a new line.
- **Dictation** (`Services/Voice/Dictation.swift`). The microphone in the field writes what is
  said into the draft and sends nothing: voice mode's recogniser, on the device and in the same
  language, with more patience for pauses (2.2 s) and one stretch of speech per tap. It takes
  the audio session the way voice mode does and gives it back when it stops.
- **Pasting a picture** (`ComposerPaste`). The field's text view turns Paste down when the
  clipboard holds no text. No public setting changes that (a paste configuration is ignored,
  and the window and application above it are SwiftUI's own), so the one text view behind the
  composer is given a subclass of its class at run time that overrides `canPerformAction` and
  `paste` and passes everything else through, as key-value observing does. With the composer
  focused and a picture and no text on the clipboard, Paste attaches the picture. If the field
  is ever backed by something else, nothing is changed and pasting is what it was;
  `EchoUITests/ComposerUITests` pastes one on every run.

### Reading

- **Chat text size** (Settings → Appearance). The transcript is set up to two steps larger or
  smaller than the iPhone's text size on the system's own scale (`ChatTextSize`, a
  `dynamicTypeSize` on the transcript alone), so it still follows that setting and every text
  style moves together. Formulas are drawn in a web view, which is told the size in points.
- **The context ring.** `Conversation.contextUsage` is the latest reply's context occupancy,
  kept as a value of its own like `title` (below), and `ContextRing` in the header shows it and
  says the token counts when tapped. Only where the backend states it: the Dashboard, and the
  OpenAI-compatible connection when the window is known.
- **Saved copies.** Every server conversation opened on the phone is already kept in
  `ConversationStore`. When the list can't be loaded, it now shows those for the active server
  under "On this iPhone" and opens them; when a row can't be fetched, it offers its copy. A
  message sent meanwhile waits in the outbox as ever.

### A conversation's own switches, and its project

On the Dashboard connection a conversation that exists on the server has two switches of its own,
in the model menu under "This conversation" (`ChatControls.swift`, `ChatControlsSection.swift`):

- **Fast mode**: `config.set key=fast value=fast|normal`. Hermes asks the provider for its fast
  or priority tier, for the models that have one, and refuses (4002) for a model that has none;
  the menu then says "This model has no fast mode" and the switch stays off.
- **Run commands without asking**: `config.set key=yolo value=on|off`, with no `scope`, so it is
  this session's flag and neither Hermes's config nor any other conversation changes. Turning it
  on asks first. The flag lives in the Hermes process: a restart of Hermes turns it off.

Where they stand comes from the server: a session's `info` when it is resumed, and every
`session.info` event after a change, which carries the stored session id. The client files each
under that id in `ChatControlStore`, taking only what an info says, since Hermes also sends short
ones (a working directory that changed). The chat's header reads the store and shows a small bolt
for as long as the open conversation runs commands without asking, whether by its own switch or
because the server's `approvals.mode` is `off`; in that second case the switch is on and
disabled, and the menu says the server never asks.

**Move to Project**, in a row's menu in the conversation list, re-homes a conversation's working
directory to a project's folder (`session.workspace.move {session_key, cwd}`), which is what
puts it in that project; Hermes Desktop does the same. The targets are the projects that are
folders, other than the one the conversation is in (the list's rows carry `cwd` on the
Dashboard). The Home bucket is no folder, so nothing can be moved back into it from here.

All three are the same in Hermes 0.21.0, 0.21.3 and 0.21.5. `scripts/hermes-lab/lab.sh controls`
checks them with the app's client: with the switch on, the stub's `rm -rf` runs unasked; off, it
is asked about again; another conversation still asks throughout. Fast mode can only be refused
there, since the lab's model has none. `-echo.demoChatControls` shows the switches on sample data
for `EchoUITests/ChatControlsUITests`.

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
(flushed around tool events, interrupts and the end of a turn). The transcript is a plain stack,
not a lazy one (a lazy one moves the page under a reader scrolling back), so everything in its
page is laid out and kept, and what a screen update costs grows with the page. Four rules keep a
streaming reply cheap:

- The page is sized by how much it holds, not by a number of messages (`Models/TranscriptPage`):
  the newest messages that fit about 30,000 characters, roughly ten screens, never fewer than
  four and never more than sixty, with "Show earlier messages" bringing in the page before.
  Each screen-height of laid-out transcript holds about a screen of bitmap, so a page of sixty
  long replies came to over a gigabyte. The page is settled when a message is added or the
  conversation changes, never while a reply streams (it would pull messages off the top under
  the reader), and it opens on a question, not on a reply cut from its question. Earlier pages
  the reader loaded stay until they send again. The page is kept as where it starts, not as how
  long it is (`TranscriptPage.Window`): counted from the end, a message added at the end pushed
  the oldest rows off the top for the one pass before the page was resized, and they were torn
  down and built again on every send, losing an open fold or a drawn diagram. Measured on a
  thread of 32 turns of ~10,000 character replies (simulator, optimized build,
  `-echo.demoHeavy`): memory 1,140 MB → 125 MB, a streaming reply 93% → 28% of a core, opening
  the thread 15 s → 8 s of CPU.

- Nothing outside the transcript reads `Conversation.messages` in a view body. Every update
  rewrites that array, and the header doing so rebuilt the navigation toolbar, the conversation
  list and the composer each time. The header reads `title`, `hasMessages` and `contextUsage`,
  which the conversation keeps as their own observed values.
- Nothing in a row animates through SwiftUI while a reply runs. Each animated frame walks the
  whole page's view tree; the waiting waveform, at 30 frames a second, took a third of a core in a
  long conversation. It is a `UIView` whose bars Core Animation moves (`WaveformBarsView`). What
  else moves in a live row is either scale, opacity or offset, which the render server animates
  (the shimmer, the mark beside the name), or is drawn rather than animated: the streaming edge
  is redrawn with each flush, which redraws the paragraph anyway, and nothing runs in between.
  The one exception is the edge settling: when no text has come for 0.7 s (the model has turned
  to a tool or to thinking) the faint, blurred last word comes up to full strength over a quarter
  of a second, once, so it isn't left unreadable for the length of the pause. The dot stays, and
  the edge is back with the next text.
  Measured, a streaming reply costs the same with the edge and the mark as without (about 20% of
  a core in a short thread and 43% in a long one, on the simulator, either way).
- A mid-stream update costs about the same whether it adds one token or twenty, so the cadence
  is the lever.

Measured in the simulator with a 32-exchange conversation (about 340,000 characters): a silent wait
went from 35% of a core to 3%, streamed thinking from 55% to 20%. Reply text stayed about 37% and
the conversation held 1.4 GB until the page was sized by what it holds (the first rule above).

"Jump to latest" is a pill over the bottom of the transcript once the reader has scrolled away
from the end, with a dot when something new has come in below since: a reply still being
written (the dot pulses, opacity only), more of one, or another message. `TranscriptView` notes
how much conversation there was when `following` went off and compares.

### Arrivals and openings

- **A message you send rises out of the composer** (`MessageArrival`): its row starts below its
  place, behind the field, and comes up into it, and the reply's waiting row holds back a beat so
  the two don't cross. One move of offset, scale and opacity on one row, decided by the message
  being under a second and a half old, so a conversation that loads doesn't move. A message
  held behind a running reply arrives in the queue the same way.
- **A picture or a diagram opens out of its thumbnail** and closes back into it: the system's
  zoom transition (`matchedTransitionSource` on the thumbnail, `navigationTransition(.zoom)` on
  the full-screen cover), in `AttachmentGallery`, `MarkdownImage` and `MermaidBlock`. It brings
  the drag-down and pinch to close with it.
- **A conversation opens out of its row or its card** (`OpeningCover`). The iPhone's list is a
  side panel and the start screen's "Continue" card swaps the transcript in place, so there is
  no pushed page or sheet for the system's zoom to attach to. A surface grows from the row (from
  where it was tapped: rows aren't measured, a list scrolls) or from the card until it covers
  what is behind, keeping the title where it was; then the panel closes, or the conversation
  loads, underneath, and the surface clears as the conversation comes forward. It is a cover and
  not a mask on the chat: a mask draws the screen off screen for as long as it is on, and taking
  one on and off rebuilds the screen under it. The growth runs on a curve with an end, not a
  spring, whose completion comes well after it looks finished and left a blank screen waiting.
  `-echo.slowMotion <factor>` stretches it for a look. Under Reduce Motion the panel slides away
  and the conversation simply appears.

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

The orb (`Views/VoiceView.swift`, `OrbFace`) is the picked orb's picture with three things drawn
on and around it:

- **The bars** (`LiveWaveform`): a KITT-style box that follows the mic or the reply's level,
  polled per frame. At rest they are a row of 6 pt dashes with one small crest running across
  them every five seconds.
- **The light** under the bars, masked by the orb's own silhouette (a bubble's tail included) and
  picked under Settings → Appearance → Orb light (`OrbLight`): **Nebula**, three patches in the
  phase colour and hues beside it on their own rhythms, the whole turning with its hue drifting
  (`DriftingBlobs`); **Aurora**, three ribbons sweeping across like a curtain (`AuroraLight`);
  **Core**, a pulsing nucleus with sparks orbiting and motes rising (`CoreLight`). The light is
  the mood and the bars are the signal, so it is held moderate and eases off toward the middle of
  the face (a smooth radial mask, about half strength at the centre to full at the rim; a deeper
  cut read as a ring round a hole, not an orb), with colour kept deep rather than pale and a soft
  dark edge on the bars. It is a little brighter and swells with the voice while live, and moves
  faster while the model thinks. Animated offsets, scales and rotations only.
- **Rings** outside the face: one in the phase colour while something is happening, with a bright
  arc chasing round it while thinking (`ThinkingArc`), and ripples widening out while listening
  and speaking, one faint one every few seconds at rest (`Halos`).

Every orb has live bars; the still ones were removed, and a saved still choice falls back to
Softer Glass. **Dark Glass** is the one orb drawn in code rather than from a picture (`GlassOrb`,
with `GlassNebula`, `GlassAurora` and `GlassCore`): a 190 pt dark face whose shade goes with the
light, a faint rim at the edge, and the light at full strength, blended normally and unmasked,
built to the three examples on the design canvas point for pixel. The canvas drew it listening,
in the accent blue; thinking and speaking turn the palette by the hue between that blue and the
phase colour, and at rest the light is dimmed. Outside the face it wears the same ring and
ripples as the picture orbs, scaled to its size. Its picker picture comes from
`design/icons/orbs/darkGlass.swift`.

The state word pushes up and out between LISTENING, THINKING and SPEAKING, in the phase colour,
and while listening each new word of the caption rises in on its own (`RisingCaption`, a centred
`Layout`). All of it is still under Reduce Motion.

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

**The screen.** Auto-lock is held off while the mic is open and while a reply is spoken, so the
phone doesn't lock on a conversation, and through the wait for the reply in between for up to two
minutes (`VoiceSession.updateScreenAwake`). Past that, a paused reply, an error and idle give it
back: the reply carries on with the phone locked, and a screen held on through a ten-minute task
is a flat battery. Reading a reply aloud from the transcript counts as speaking.

**Talking over a reply** (Settings → Voice → Talk over replies: off, with headphones (the
default), or headphones and speaker). A reply can be interrupted by speaking, not only by tapping
the mic. It was tried twice in September 2026 by letting the recogniser listen while Redde spoke
(echo-cancelled, then with Redde's own words filtered out), and both times the recogniser wrote
something down and Redde interrupted itself. So now the recogniser never hears a reply:

1. When a turn starts, the mic opens behind the reply in a held state
   (`SpeechRecognizer.startHeld`): the engine runs, the analyzer is ready, and the audio goes
   nowhere but a one-second buffer.
2. While the reply is spoken, only the level is watched (`BargeInDetector`, fed from the tap on
   the audio thread): loud enough for where the microphone is, for about a sixth of a second,
   and not in the first 1.2 s after the sound starts or resumes.
3. A voice holds the reply (`output.pause()`), and only then does the recogniser listen, starting
   with the buffered second so the first word isn't lost, to a room Redde is no longer talking
   in. Words within a second and a half make it an interruption: the reply and the turn on the
   server stop, as with a tap, and what is being said is the next message. No words, or only a
   listener's "mm-hm" or "okay" (`Backchannel`), and the mic goes back to held and the reply
   carries on.
4. A reply that ends by itself in hands-free goes straight to listening on the mic that is
   already open, with none of the buffered audio.

**Interrupt with: only "stop"** (the same screen; "Anything you say" is the default). For a room
where other people are talking: step 3 changes. A voice does not hold the reply. The recogniser
starts transcribing while the reply plays on, and only one thing in what it writes down matters:
the word "stop" (`StopWord`: a word of its own, and not "don't stop"). That ends the reply, the
turn and hands-free, with the same "Okay." as a stop phrase between turns, and nothing that was
said becomes a message. When the talking has been over for two and a half seconds the mic goes
back to held. Here the recogniser does listen while Redde speaks, which is what failed when any
word counted; with one word that counts, what else it makes of the room is thrown away. On the
speaker, at 75% volume, it transcribed a person talking and none of a reply that said "stop" a
dozen times over them; on headphones the reply isn't in the microphone at all.

**Stop phrases** (Settings → Voice). Between turns in hands-free, an utterance that means "that's
all" ends the conversation and never reaches the agent (`StopPhrase`: the whole utterance, with or
without "okay", "Redde", "please" or "thanks" around it, so "stop by the store" is still a
question). The built-in list is English. A person's own phrases (`Settings.stopPhrases`, up to
twenty) are heard beside it, which is how another language gets one: the recogniser writes
"Stopp" in German, and neither list nor word would ever match it. They are compared lowercased
and without accents or punctuation, so "basta cosi" typed is "Basta così." heard. With "Only
stop" they stop a reply too (`StopWord.heard(in:own:)`): there a phrase counts as a run of words
anywhere in what was heard, not after "don't" and its like, and one written without spaces
(Chinese, Japanese) counts wherever it stands.

On the phone's speaker this needs the system's echo cancellation for as long as Redde speaks, so
the session stays in voice-chat mode instead of switching to `.default` for the reply
(`AudioSessionController.setReplying`), and the reply plays at call volume; that is why the
speaker is a separate choice, off by default. On headphones nothing of the reply reaches the
microphone and no echo cancellation is used; the mic staying open keeps a Bluetooth headset in
its call profile while Redde speaks. Never in the car, whose audio and own echo handling are
untested. What it was measured on, and the numbers behind the thresholds, are in
`BargeInDetector.swift` (an iPhone 15 Pro Max, speaker and AirPods, Kokoro and the built-in
voice, 2026-10-07). Not tried: the earpiece, other phones, a reply several minutes long.

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
Approve / Deny and reply actions. A finished reply's banner takes the next message too: Reply
sends it into the conversation the banner came from (behind an unlock when the app's own lock
is on).

**When Redde is closed.** Those stop when iOS closes the app. From then on a paired Hermes sends
them itself (Settings → Voice → "Notify when Redde is closed"): a plugin there seals a short note
with a key only it and the phone hold, a relay passes it to Apple unread, and the `EchoPush`
notification extension opens it (`Shared/PushSeal.swift`, `PushService`). An app with that
Hermes's Dashboard login can have Hermes install the plugin (`PushPlugin.swift`: the Dashboard's
own plugin routes, `GET /api/dashboard/plugins/hub` and `POST /api/dashboard/agent-plugins/install`,
with the folder of this repository the terminal's command names). Hermes 0.21.5 loads it into the
running gateway and Dashboard and says so, and pairing can go straight on; 0.21.0 and 0.21.3 put
it on disk and switch it on, and load it when they next start, so the screen then asks for a
restart on that machine, which no route can do for the Dashboard itself. A plugin older than the
one this build's source has (`PushPlugin.version`, held to `plugin.yaml` by a test) is offered an
update, which is the same install again, replacing. Pairing is one tap for
an app signed in to that Hermes's Dashboard, and otherwise a QR code from `hermes redde-push pair`. A tap opens the conversation, fetched from the server; Reply on a
reply's banner sends into it, and Approve and Deny on an approval's answer it, all behind an
unlock; a question's takes the answer, typed or by a button for each of its choices. It announces a
finished reply, an approval, a question, a sudo password or a secret being
asked for, a turn that ended without a reply, and a handed-off task coming back; Hermes has a
plugin hook for only the first two, and how the rest are told is in [docs/push.md](push.md), with
the design, the wire formats and what has to happen before it ships.

**Notification sound.** Settings → Voice → "Notification sound" silences all of them. The app's
own banners are posted without a sound; a pushed one arrives with Apple's default, which the
relay always asks for, and the notification extension takes it off, reading the setting from the
app group (`NotificationSound`).

**A turn the app didn't see the end of.** A question is saved when the host has a session for it,
not only with its reply, so an app that iOS closed mid-turn comes back to the right conversation.
When it comes forward, a Hermes conversation that ends on an unanswered question is fetched again
(`Conversation.catchUp`). On the Dashboard, opening a conversation whose turn is still under way
joins it (`HermesTransport.rejoin`): the reply so far, what follows, and the card for whatever
the agent is waiting on. Stop stops a joined turn; leaving the conversation only stops listening.

## Siri, Shortcuts and controls

Three App Shortcuts: "Ask Redde", "Talk with Redde" (hands-free) and "Ask a Profile" ("Ask Work in
Redde"); Siri also answers to "Hermes" and "Sol". Siri only opens the app, which then listens with
its own recognizer; long free-form questions through Siri's dictation are unreliable. "Ask Redde a Question" in Shortcuts takes text and returns
the reply as text. The `EchoControls` extension provides Control Center, Lock Screen and Action Button
controls (via an App Group launch flag), Home Screen widgets (Last reply, Ask Redde, Needs you,
Context) and the Live Activity (`Services/TurnActivity.swift`).

A Live Activity outlives the app, so one for a reply that never finished would sit on the Lock
Screen and in the Dynamic Island looking busy for hours when the app crashes, is closed or is
suspended mid-reply: nothing is left to end it. Every update therefore carries a stale date two
minutes off, and a heartbeat re-sends the state every 45 seconds while the reply runs, so a long
quiet tool doesn't go stale under a live app. Once updates stop, the system marks the activity
stale and its views show "Reply interrupted" with no pulse and no clock (the wording lives with
`EchoTurnAttributes`, where the app's tests can reach it). Two minutes is as soon as the system
acts; asked for less, it still waited that long. The next launch ends whatever an earlier run
left (`TurnActivity.clearStrays`).

A command waiting for a yes or no takes the activity over: "Needs your approval", the command,
and Deny and Approve, on the Lock Screen and in the expanded island. The buttons are Live
Activity intents (`Shared/ApprovalIntents.swift`), which the system runs in the app's process,
so the answer goes to the conversation that is waiting, by the same door as the notification's
buttons. Approve asks for the device to be unlocked; Deny doesn't. A stale activity shows no
buttons: the app that would carry the answer has stopped. `-echo.demoApproval` puts one up to
look at.

### Status widgets: Needs you, and Context

Two widgets say where things stand without the app being opened (`EchoControls/StatusWidgets.swift`;
what they show is kept in the App Group by `Shared/NeedsYou.swift`).

**Needs you** lists what an agent has stopped for: a command to approve, a question, the sudo
password, a secret. Small, medium, and the three Lock Screen sizes. One entry per conversation,
keyed by the Hermes session, since Hermes waits on one thing at a time in a session. Two things
write the list:

- The app, while it follows a turn (`Conversation.noteWaiting`), and it takes the entry away the
  moment the request is answered or expires, or the turn is stopped or ends. Leaving a turn the app
  only joined keeps the entry: that turn goes on on the host and still waits.
- The notification extension, for a note a paired Hermes sends (`NeedsYou.take`): this is how a
  request made while Redde is closed gets onto the widget. A later note that the turn ended, with
  a reply or without, takes it off; so does answering from the notification, and opening the
  conversation, which then joins the turn and says so again if it still waits.

The app and a note can both speak of the same request, seconds apart: the entry is one, and a note
that arrives after the app has seen its request answered doesn't bring it back (what was settled
is remembered for as long as Hermes would have waited; the start of the command is compared, since
the plugin cuts a long one short). Each entry also has an end, by Hermes's own defaults (an
approval five minutes, a question an hour, the sudo password two minutes, a secret five), and the
widget's timeline has an entry at each end, so it lets go without the app running. A server set up
with other timeouts isn't known to the phone; an entry that outlives its request is put right when
the conversation is opened. Something waiting gives the timeline entry a relevance, which is what
brings the widget to the top of a Smart Stack.

A tap opens the conversation that waits (`echo://session?id=…`, handled like a tap on a pushed
notification, `LaunchRouter.requestSession`); in the medium size each row is its own link. The
widget has no Approve and Deny of its own: the card in the app, the Live Activity and the
notification have them.

**Context** shows how full the model's context was at the newest reply that said, as the ring in
the chat's header does: small, and the three Lock Screen sizes. The app writes the reading when a
turn ends and when a conversation is opened (`Conversation.publishContext`, `ContextReading`); a
conversation with no reading yet leaves the one before on the widget, under its title. Amber from
three quarters and red from nine tenths, as in the app.

Both are written through `StatusWidgets`, which reloads a widget only when what it shows changed.
With the app lock on (Settings → Privacy), neither shows a command, a question or a title, only
that something waits and how full the context is; the flag is mirrored into the App Group
(`NeedsYou.hidesWords`) because the widgets and the notification extension can't read the app's
settings. Erase Everything clears both.

`EchoTests/StatusWidgetTests.swift` covers the list, the notes, the timelines and the conversation's
hooks, and draws every size. The widget file is compiled into the test bundle for that
(`WIDGET_VIEWS_IN_TESTS`). `-echo.demoWidgets` fills both with sample data for a look on a Home
Screen.

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

A CarPlay scene in the voice-based conversational category (iOS 26.4+). A tab bar with two tabs.
**Ask** is a list holding one row of three cards (`CPListImageRowItem` with card elements): **Ask**
and **Talk** carry on the conversation the phone has open, **New Chat** starts another. Above them
the row names that conversation ("Now in …"), and that line leads to the other tab. **Chats** is
a list of the phone's conversations to pick one from (`CarPlay/CarPlayChats.swift`: the phone's
list in its order, as names and times; a session nobody named is "Untitled chat", never the
preview of its last message), the open one marked with a check at the trailing edge. The list is
read when the car connects, when the tab is opened and when the open conversation changes. New
Chat and a picked chat listen in the mode Settings → Voice gives the phone's voice button. Each of
them ends on a voice-control card (Listening, Thinking, Speaking, Muted, Needs your phone) with
**End** and **Mute** in its bar: Mute shuts the mic and keeps the conversation
(`VoiceSession.mute`, which also gives the car its audio back), End stops whatever Redde is
doing. A voice-control template takes five states and no more, so a finished reply closes the card
and a failure is an alert. Replies are spoken only.

CarPlay sizes everything in points and nothing to the screen, and two of its choices decide this
layout (both found by drawing its own views, below). A grid template's button has a 40-point
picture on every screen, so the first tab is cards: about 85 by 112 points each, the largest
buttons there are, which fill a 400-point-wide screen and sit at the leading edge of a wider one.
And a voice state with action buttons is laid out title, picture, buttons, with the picture
given a third of whatever height is left: 10 points on a 240-point-high screen, 58 on a
480-point one. Without them it has that height less 150 points, up to its full 150. Builds 260
and 261 had Mute and End as action buttons, and on a car the card stood there with words and no
picture. So no state has action buttons, and the controls are bar buttons
(`CarPlaySceneDelegate.barButtons(for:)`). End is the leading one on purpose: a card that
offers nothing there gets a close button from CarPlay, which takes the card down without the
conversation being told. The car's own Back button still does that; nothing here hears of it.

The brand lives in artwork drawn in code (`CarPlay/CarPlayArtwork.swift`). The card's pictures
move: a state's image is an animation to CarPlay (a loop of 0.3 to 5 seconds, 150 points at
most), so Listening is a swell running across the bars, Speaking is the bars in gold rising and
falling together, and Thinking is the spark making a quarter turn. They are pictures drawn ahead
of time at the car's display scale, about thirty to a loop: unlike the phone's waveform they
cannot follow the level of a voice. Reduce Motion gets the still pictures. On iOS 27 each state
also has a backdrop behind the whole card (`voiceBackdrop`): graphite with a soft light, mist
while you are heard and gold while Redde thinks and speaks, as one image holding a dark and a
light picture, because the card writes its words in the car's own appearance.

`scripts/carplay-preview.sh` draws all of this without a car: `EchoTests/CarPlayPreviewTests.swift`
hands the app's real templates to the view controllers CarPlay itself uses (in the simulator's
CarPlaySupport framework, by class name, so it can break with any iOS release) and writes PNG
files at car-screen sizes in both appearances, with the measured sizes beside them. It leaves out
the car's status bar and the tab bar. Look at its pictures before changing anything here: two
rounds of this work were done from the headers alone and both looked wrong on a car.

Declaring the scene enables multiple scenes, so the WindowGroup routes
external events to the existing window (`handlesExternalEvents` in `EchoApp`); re-check the Action
Button, Control Center and widget paths on a device after changes here.
`scripts/carplay-simulator.sh` previews the car screens in a separate, git-ignored simulator
project. The `audio` background mode keeps a conversation going when the car screen switches to
navigation (or the phone locks): without it iOS cuts the microphone and silences the reply as soon
as Redde leaves the foreground, and the continued-processing task (above) only covers the wait in
between. The cards and the card's bar (2026-10-10) are pressed by `EchoTests/CarPlayTests.swift`
and have been seen in the preview's pictures, not yet on a car's screen. The flip side: a mic left
open on a locked phone
would now stay open, so when every scene goes to the background while listening, the session
stops (`VoiceSession.leftForeground`) unless hands-free is on or the car is connected
(`CarPlaySceneDelegate.isConnected`). A reply being thought about or spoken is never stopped there.

## Apple Watch

A watchOS app (`Watch/`, target `EchoWatch`, embedded in the iPhone app): ask a question by
dictation, read the answer, hear it read aloud, and carry on a conversation from the server. It talks to Hermes itself, over plain
HTTP: the Hermes API or the fast lane. The phone hands over a `WatchConnection`
(`Shared/WatchSync.swift`) as WatchConnectivity application context. A phone on the fast lane
hands that over; a phone on either Hermes connection hands over the Hermes API, with the profile
path and key, which is the same agent; whichever of the two isn't set up, the other stands in.

Never the Dashboard itself. It runs over a WebSocket, and watchOS keeps "low-level networking",
WebSockets included, from an ordinary app: only an app streaming audio or on a call gets it
(Apple's TN3135). The simulator allows it all the same, so the Dashboard worked there and failed
on a wrist, and for a while the phone did hand it over.

A phone with nothing but the Dashboard asks for the watch instead (`WatchConnection.Kind.phone`,
`Shared/WatchRelay.swift`). The watch sends its question to the phone over WatchConnectivity; the
phone runs the turn on the Dashboard, in a session of the watch's own (`Services/WatchRelayHost.swift`),
and the watch follows it by asking every second and a half for where it has got to
(`WatchRelayClient`). Each answer is the turn whole, so a lost one costs nothing, and each
question is a message that wakes the phone's app, which is what keeps it running in the
background; a background task covers the gaps. The phone also queues the finished reply
(`transferUserInfo`) for a watch that stopped asking. Its limits: the phone has to be in reach,
and a phone that was restarted while locked can't read the Dashboard password until it is
unlocked once (the session cookie usually spares it the need). The order of preference for a
phone on a Hermes connection is the Hermes API, since the watch can then ask with the phone out
of reach, then through the phone, then the fast lane.

The phone pushes on launch, when it comes to the front, when Settings or Setup close and on a
server switch (`Services/WatchLink.swift`); the watch asks for a copy when it has none
(`Watch/PhoneLink.swift`). The key goes into the watch's Keychain, the rest into its defaults.

Questions go through the same transport files as the phone — `HermesTransport`,
`HermesSessionsTransport`, `ChatCompletionsTransport`, `SSEParser`, `JSONValue`, `Message` — listed
one by one in `project.yml`, since the rest of the app assumes iOS. On the Hermes API the watch
keeps one session of its own ("Apple Watch · date"), made on the first question and remade if the
gateway deletes it; on the fast lane it keeps the last six exchanges as history. The agent is told
the reply will be read aloud and to keep it short and plain. Replies are spoken with Kokoro when
the phone uses it (one WAV per reply from the phone's server), else the system voice
(`AVSpeechSynthesizer`, in the reply language when one is set). On Bluetooth headphones the
reply plays on after the wrist goes down (`audio` background mode, long-form audio policy); on
the speaker it plays while the app is on screen, which is all watchOS allows. A command the agent
wants a yes or no for is answered on the wrist, Approve or Deny, on either road (over the Hermes
API directly, or through the phone); a single question from the agent is answered there too when
the phone is asking (its choices as buttons, or dictated). A password is not for the wrist: the
watch says to open the conversation on the phone. The phone's own notifications reach the wrist
on their own. `Watch/AskReddeIntent.swift` is the Ask Redde App Shortcut: a Siri phrase on the
watch, and what the Ultra's Action button runs (Settings › Action Button › Shortcut); it opens
the app and starts dictation once the screen is up.

**Carrying a conversation on.** A watch that talks to the Hermes API itself can list the server's
recent conversations (`Watch/ChatsView.swift`, `Models/WatchChats.swift`; the list button at the
top left): the twenty newest that have anything in them, under their titles. Picking one makes it
the session the watch's questions go into, and brings up its last question and answer, read from
the end of its transcript, with its title above them. "New Chat" goes back to a session of the
watch's own. The session and its title are kept, so the watch is still in that conversation the
next day; another server, or a session deleted there, starts over. Through the iPhone and on the
fast lane there is no list: the phone's end of the relay knows one question at a time, and the
fast lane keeps no conversations.

**The complication.** "Ask Redde" on a watch face, in the circular, corner, rectangular and inline
sizes (`WatchWidgets/`, target `EchoWatchWidgets`, a WidgetKit extension inside the watch app). A
tap opens the app with `redde-watch://ask`, which starts dictation as the Ask button does. It
shows nothing that changes and shares no data with the app, so it has no timeline to keep and no
app group. Its look lives in `WatchWidgets/AskComplication.swift`, which the watch app compiles
too.

Debug launch arguments for the simulator, which can neither dictate nor receive the
phone's handover: `-echo.connection <hermesAPI|fastLane|phone> <url> <key>` (the phone is then not
listened to: a paired simulator's phone would hand over its own), `-echo.ask "text"`,
`-echo.preview <state>` (among them `approval` and `question`), `-echo.chatList`, `-echo.openChat <n>`,
`-echo.complications` (the complication's sizes side by side, since a face can't be set up from a
script) and `-echo.link <url>`.
Paired simulators don't treat a watch app installed with `simctl` as the phone's companion, so
the handover itself is tested on a real watch.

## App and settings

- **Themes:** seven (Messages, Paper, Slate, Terminal, Amber CRT, Hermes, Code), each with light and
  dark faces and the user's own accent and bubble colours. 13 app icons and 12 voice orbs with three lights inside.
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
- **Custom headers:** for a reverse proxy that asks for a header of its own (`Models/CustomHeader.swift`,
  Settings → Connection details). Per server, names and values both in the Keychain. They ride on
  every Dashboard request and WebSocket handshake (the client's `URLSession` carries them, with
  the Cloudflare pair) and on every Hermes API request, the watch's included (`WatchConnection.headers`,
  kept in the watch's Keychain). A header the app sets itself (the API key's `Authorization`) wins.
  A setup code made with its secrets carries them, one `header=Name: value` parameter each, up
  to eight (the one parameter a code may repeat); the confirmation and the web page name them
  and never show a value. Not sent to the OpenAI-compatible endpoint or the speech server.
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
