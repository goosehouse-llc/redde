# Architecture

How Redde works, for contributors. For what it is and how to build it, see the [README](../README.md).

## Principles

- **Your server, nothing else.** Requests go only to the servers the user configures. No analytics,
  no crash reporting, no service of our own in the request path.
- **On the device where possible.** Speech recognition (SpeechAnalyzer) and the built-in voice
  (AVSpeechSynthesizer) run on the phone. The only optional remote audio services are a Kokoro
  server the user runs and the user's own Hermes, which speaks with the voice it is set up with
  (so the reply's text may go on from it to the provider chosen there; Settings says which).
- **Secrets in the Keychain.** Keys and passwords are stored `WhenUnlockedThisDeviceOnly`, never in
  UserDefaults, source or config files; with Sync with iCloud turned on, a server's keys and
  passwords go in iCloud Keychain instead (end-to-end encrypted; see [Sync with iCloud](#sync-with-icloud)).
- **One opt-in exception:** Settings → Siri → "Let Siri use Redde" (iOS 27) lets Apple Intelligence
  hear messages and see recent conversations. Off by default; see [Siri AI](#siri-ai-ios-27-opt-in).

## Connections

Three, chosen under Settings → Connection:

| Connection | Endpoint | Auth | What you get |
| --- | --- | --- | --- |
| Hermes Dashboard | `hermes serve`, `ws://…:9119/api/ws` | Dashboard username + password (cookie login), or a browser sign-in (bearer tokens); then a 30 s WebSocket ticket | The desktop-gateway protocol: JSON-RPC over one WebSocket. Live `reasoning.delta`, tool events, approvals, and slash commands (`slash.exec` / `command.dispatch`) |
| Hermes API | The gateway's API server, `https://…:8642`: each turn a run in the conversation's session (`POST /v1/runs`, followed at `/v1/runs/{id}/events`; `/api/sessions/{id}/chat/stream` where there are no runs) | Bearer `API_SERVER_KEY` | The shared session ledger: every gateway session from Telegram, Discord, the CLI and Redde, resumable from the list. Streams reasoning, tool starts and results, subagents, approvals and usage |
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

**Each bot's skills** are in Edit Bot → Skills (`BotSkillsList`, 2026-10-22). The list is the bot's
own, from `GET /api/skills?profile=<bot>`, and switching one off writes the bot's `skills.disabled`
(`PUT /api/skills/toggle?profile=<bot>`), right away rather than on Save. On, the bot sees the skill
listed and reads it only when it needs it; off, it doesn't see it at all. Every release from 0.21.0
takes the profile on both routes. Lab `bots` checks that a skill switched off for a bot is off for it
alone and can be switched back on.

**Pinning a skill** makes it always loaded: the bot reads it in full at the start of every message
(`skills.auto_load`), and Hermes needs the bot's Skills tool on for that. Use: the Home bot keeps
its Home Assistant skills at hand and reads the rest only when needed.
- **How it's stored:** Redde reads the list with `GET /api/config?profile=<bot>&include_defaults=false`
  and writes it with `PUT /api/config?profile=<bot>` `{"config": {"skills": {"auto_load": [...]}}}`.
  The Dashboard deep-merges, and a list replaces the old one, so nothing else in the config changes
  (every release from 0.21.0).
- **Switching a skill off** unpins it.
- **When it takes effect:** Hermes rebuilds an ongoing Bot Chat's prompt only when its toolsets,
  switched-off skills, skill files or SOUL change, not when `auto_load` does. So a pin applies to
  new chats, and to the bot's chat once it starts fresh or is condensed; the screen says so.
- **Lab:** `bots` checks that a pin is the bot's alone and that its other settings stay.

**"The Dashboard login"** counts a Dashboard that lets the phone in with nothing stored: one with no
password, or a login's cookie still good (`HermesServeClient.canUse`, `letInWithoutLogin`). The chat
connection already got in that way, by its `api/sessions` probe. Settings → Agent, files the agent
sends, and pages ask `canUse` before saying a login is missing (2026-10-22: everything there was grey
while chats worked).

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
- **All Profiles** (2026-10-22, after a Reddit request: Hermes Desktop shows every profile's sessions
  at once). A profile menu sits at the top of the chat list once the server has more than one
  profile. It lists All Profiles and each profile; picking one switches the app as Settings does,
  in one tap. With All Profiles on, the list holds every profile's chats, newest first
  (`SessionBackend.everyProfile`), and another profile's chats carry its name as a tinted tag.
  - **Where the list comes from:** the Dashboard's `GET /api/profiles/sessions?profile=all` (every
    release from 0.21.0, rows tagged with `profile`) whenever the Dashboard can be used, on either
    connection. On the Hermes API alone there is no such list, so each profile the phone knows
    (`ProfileCatalog`, the API bots) is asked at `/p/<profile>/` with its own key or the main key.
    A profile that takes neither is left out.
  - **Bots' sessions:** another profile's Bot Chat and group-chat sessions are its bot's, so they
    stay in the Bots section and aren't rows.
  - **How a row is reached:** it carries `elsewhere: ProfileRoute` (profile, and whether by the API).
    A Dashboard row's profile is noted for its id (`noteProfile`), so every call about it names
    that profile. Its housekeeping uses `SessionBackend.owning`. The list itself always uses the
    selected profile's backend (`SessionBackend.list`), whatever chat is open.
  - **Opening one:** the conversation keeps the route as `Conversation.elsewhere`, saved with the
    chat in `ConversationRecord.elsewhere`. Calls go to that profile the way a bot's chat's do
    (`routeProfile`, `apiProfile`, `connection`). The header names the profile where the agent's
    name goes. New chats start in the selected profile.
- **Cards in replies** (asked 2026-10-22, after Conduit's rich cards; our own format and code:
  `ReplyCards`, `ReplyCardViews`, the plugin's `cards.py`). The agent calls the Redde plugin's
  `redde_show` with up to four cards: a map (pins, or a route from a place or from where the
  person is), a list of places (rating, category, address, a note, a phone, a website), the
  weather (now, by the hour, by the day, in °C or °F). Nothing goes to the phone: the tool checks
  the cards and says what each shows, and the app reads the call itself. The step keeps a card
  call's arguments as their JSON (`ToolActivity.args`), not the reading text other calls get.
  Live on the Dashboard the cards arrive with `tool.start`; the Hermes API's stream names the
  call without its arguments, so the app reads them from the transcript as the reply finishes
  (`settleCards`). Read back, both histories carry them (`ReplyCards.resolve`, through
  `tool_call` too). Drawn with MapKit (a still map in the chat, a tap opens Apple Maps, with
  directions for a route; between two named places the route is drawn, worked out by
  MKDirections; from where the person is, Maps works it out, so the app never asks for the
  phone's location) and the system's weather symbols. A place without coordinates is looked up
  on the phone (`PlaceLookup`, MapKit's search, once a run). Lenient: numbers as text, lat/lng,
  "sunny" for clear; a card or place that can't be drawn is dropped, never the whole call. The
  tool is always offered, never behind tool search, unless Settings → Agent → Cards in replies is
  off (`/redde-push cards off`, `ReplyCardsSwitch`; its description rides on every prompt); off,
  it also refuses a call that reaches it through `tool_call` (0.21.5 lets a model). Plugin 1.6.0.
  `lab.sh cards` passes on 0.21.0 to 0.22.2; `ReplyCardsTests`, `ReplyCardsUITests`
  (`-echo.demoCards`), `companion/hermes-plugin/tests/test_cards.py`.
- **All Servers** (2026-10-22, after a Reddit request: several gateways in one list, each row
  tagged with its server; `AllServers`, `RemoteServer`). The server menu at the top of the chat
  list (shown once there are two servers) has All Servers above the servers; with it on, the list
  holds every saved server's chats, newest first, another server's with its name on a grey tag,
  and new chats still start on the server the app is on (the menu says which).
  - **Where the rows come from:** the server the app is on as before, at once; then every other
    saved server, all asked together, each by the connection its record is used with (its
    Dashboard's REST `api/sessions` through a `HermesServeClient` of its own, kept while the
    record is unchanged, or its Hermes API at its profile's `/p/<profile>/`) and the secrets filed
    under its id (password or browser sign-in, API keys, Cloudflare Access, custom headers). Each
    has eight seconds; one that doesn't answer is named above the list. A Bot Chat and a group
    chat's session are left out. A chat already listed (one Hermes saved twice, by its Dashboard
    and by its API) is listed once.
  - **Rows:** `SessionSummary.otherServer` (`ServerTag`: id and name), never decoded from the
    server. Another server's row opens by switching to that server (`ServerSwitcher`) and opening
    it there as one of its own; it has no swipes, its menu is Open on <server>, and it can't be
    selected, so nothing about it ever goes to the wrong server. Live marks (working, needs you)
    are the active server's alone; another's shows the unread its list gives.
  - **Not merged:** bots and group chats, projects, Cron, Kanban and message search are the active
    server's. `lab.sh servers` saves the lab's Hermes twice (Dashboard, API) and a third server
    that is off, on 0.21.0 and 0.22.2; `AllServersTests`, `AllServersUITests` (`-echo.demoAllServers`).
  - **Not covered:** message search and the project tree stay the selected profile's. Session ids
    are assumed unique across profiles (Hermes makes them from the time plus random characters).
  - **Lab:** `bots` runs `anotherProfilesChatIsListedAndGoesOnInItsProfile` (Dashboard, and the
    Hermes API with the Dashboard's login). `apibots` runs
    `onTheHermesAPIAloneAnotherProfilesChatIsListedAndGoesOn`.
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

### Bots

Hermes's Bot Mode, as Hermes Desktop has it, on the Dashboard connection and on the Hermes API
(below; `ServerBots.swift`). A bot is a Hermes profile with one conversation of its own: the session titled exactly "Bot Chat" on
that profile. Hermes counts every profile as one. The chat list's **Bots** section lists them once
the server has a profile besides the main one, and has New Bot either way (Settings → Hermes server
→ Bots in the chat list turns it off). Each bot is a little creature of its own (`BotAvatar.swift`): a speech bubble at
heart, its tail the corner nearest its bottom left drawn sharp as a message bubble's is (a round or
egg shape gets a corner there, a pointed one sharpens that point), in one of eight shapes (round,
egg, pill, capsule, burst, pick, hex, diamond), white eyes glancing somewhere, on some a small mouth
or a mark (an antenna, a sparkle, freckles, blush), in a gradient of its own. All of it comes from
the profile's name, except the main profile's, which is always Redde's own bubble (`BotFace.main`):
a message bubble, nearly square, its corners the theme's and the bottom left one tucked in (a
reply's side), in the theme's bubble colour (the prompt line's in Terminal and Amber CRT; asked
2026-10-21, after a day of the Code theme's pale sky in every theme), the whites of its eyes rimmed
when that colour is pale. Its face can be picked like a bot's, and two colours are its alone, past
the palette: Theme (`BotFace.themed`, the one it has unpicked) and Code Blue (`codeBlue`, #CBF0FF
whatever the theme); the other bots keep off blue all the same. A bot's face can be picked
instead (Change Face…
on its row, or in its chat's ••• menu; `BotFacePicker`): shape, eyes, mouth, mark and colour, kept
on the server in the profile's `ui_meta` under `redde` (`face`, a short code; compare-and-swap on
its revision), so every Redde there shows it. Four shapes are for picking only (a ghost, a rounded
square, a star, a blob): what a name gives is drawn from the first eight (`Shape.seeded`), so no
bot's creature changes when shapes are added. The main agent's face can be picked too (Redde's
bubble is offered to it alone, and "Its Own Face" goes back to it); `BotDirectory.mainFace` is what
the voice orb, CarPlay's Redde look and the list then draw.
**Pictures from Hermes Desktop** (2026-10-22, a Reddit request). A bot given a picture in Hermes
Desktop (`assets/avatar.*` in its profile; `has_avatar` in `profiles.list`) shows that picture
wherever its face is drawn:
- `BotFace.picture` names the profile, and is never written into the face's `code`.
- `BotAvatar` draws the picture as a rounded square, a little inside the face's frame.
- `BotPictures` fetches it with `profiles.get_asset` (every release from 0.21.0), once per launch. It
  keeps a 384-pixel copy per server under Caches, so lists show it at once.
- Settings → Appearance → Pictures from Hermes switches it off (it is on by default).
- The face picker still shows the creature.
- `-echo.demoPicture` gives the demo's Scout a picture. Lab `bots` checks that a picture set as
  Hermes Desktop sets one comes over for that bot and no other.

`BotFace.faces(for:picked:)` keeps the picked ones and keeps the others apart, with a shape and a
colour each while there are some left (none gets Redde's shape, nor the standard theme's blue). Kept
clear of other Hermes apps' looks on purpose (Cadu's clouds, flowers, ghosts, hearts, pears, cats
and bears; plain dark oval eyes). The creature is in the list, the @ menu, the chat's header and
beside its replies; `-echo.screen botGallery` (DEBUG) shows a dozen large, and Redde in every theme.
Settings → Appearance → Bot faces (`Settings.botFaces`, synced, on unless turned off; asked
2026-10-21 for people who'd rather not have faces) draws every bot, Redde too, as its initial on a
circle of its colour (`BotAvatar` with a `name`; without one, where a face is picked, the face is
drawn all the same), on CarPlay's Bots tab and the watch's too; voice mode then shows the voice orb
for a bot and a room, with the Bubble in place of Redde's face (`VoiceOrb.shown`). The faces stay
on the server, so turning it back on shows them again.
Rows come from `profiles.list` (every release from 0.21.0): the bot's name (its Hermes Desktop
title, its profile's display name, or the profile's name; the main profile goes by the name in
Settings → Name), and its chat's last line and time (`canonical_session`).

- **A bot's chat** is found by its title on the bot's profile every time it is opened
  (`session.list {profile, title, include_hidden}`), never by a stored id: Hermes Desktop lost
  people's chats each time it kept a pointer (its `src/AGENTS.md`, "Bot Mode"). The first open makes
  it as Desktop does (`session.create {profile, title, hidden, follow_profile_config}`, then
  `session.title` at once so a second open finds it); a lookup that fails, or finds nothing where
  the roster says there is a chat, refuses rather than make a second one. It is hidden from the
  profile's conversation list, runs on the bot's own model and settings, and is never renamed in
  Redde (the title is what finds it). A new conversation from it is with the agent again.
- **Its length:** Hermes keeps a bot's chat as one long conversation and condenses it as it fills
  (from three quarters of a window under 512K; the newest part word for word, the rest as a
  summary, then on in a linked part, which the roster's `canonical_session.resolved_id` names);
  `/compress` in the chat does it at once. **Start Fresh** (the toolbar's button in a bot's chat,
where a new conversation is in the ••• menu, and ⌘N as anywhere) is the clean
  slate: the chat is archived, kept on the server with its messages (`startFresh`,
  `session.archive`, Hermes 0.22 and later), Hermes then names no chat for the bot, the roster is
  read again, and the next open makes a new chat as the first did. Hermes refuses to rename a
  bot's chat ("its name is its identity"), and before 0.22 has no way to set one aside, so there
  Start Fresh says so and points to `/compress`. What the bot saved to its memory stays with it.
  `HermesLabBotsTests` checks both on 0.21.0 to 0.22.2.
- **Its profile, on every call:** whichever profile Redde is set to, a bot's chat is a session of
  the bot's profile, and Hermes only finds it when told which. `Conversation.bot` (kept in the
  saved copy) has the client note it (`HermesServeClient.noteProfile`), and from then on every
  profile-scoped call and REST route about that session, by its stored or runtime id, names the
  bot's profile. The main profile is named as "default".
- **@mentions** in a bot's chat: typing "@" offers the other bots; a tag names a bot by its handle
  (the profile's name; "hermes" for the main one), its friendly name ("@research-buddy") or a name
  it had before. The message goes with Hermes Desktop's note saying which bot each tag means
  (`BotMentions.note`, after the message and before the reply-language note), and the agent passes
  the question on with its `message_agent` tool, in words of its own. Redde hides the note when it
  shows the message (`MentionNote.strip`). Outside a bot's chat a tag is plain text: only a bot's
  chat has the tool.
- **A reply that writes as the person** (2026-10-20; `BotMessages.inventedTurn`, `InventedTurnNote`).
  A local model sometimes carries on past its answer into a made-up turn of the person's, in
  Hermes's own frame for a message sent in (the Ops bot ended a reply "Q / [Out-of-band message
  from Alex, delivered as a new user message] / Turn the office"). Redde shows the reply up to
  that frame (a stray letter before it with it) and, in place of the rest, "<bot> wrote a message
  as if from you", its words behind a tap; voice mode reads nothing from the frame on
  (`SpeechOutput.madeUpTurn`), and a row's preview stops there too. The owner's model server
  stops generation at those frames besides (llama-swap `setParams.stop`, outside this repository).
- **Schedules** (asked 2026-10-20; `BotRoutines`, `RoutineWhen`, `BotSchedulesView`). Schedules…
  in a bot's row menu and its chat's ••• menu gives the bot jobs on a timetable, made as Hermes
  Desktop makes its Routines: cron jobs in the bot's own store (the Dashboard's cron routes with
  `?profile=<bot>`), named with Desktop's tag ("[bot:scout] What to wear") so Desktop lists them
  as the bot's too, delivering into its Bot Chat (`deliver: bot-chat:<bot>`, the form that names
  the bot, which every release reads the same). A run is the bot's (its personality, model and
  cron tools); Hermes puts its output into the Bot Chat under a banner ("[Cronjob "…" output —
  scheduled job, not the user …]"), and the bot answers it there, a second turn. Redde shows that
  row as the schedule's, folded ("What to wear ran", `Delivered.routine`), never as the
  person's, and the bot's answer after it. When is picked in words (every day, weekdays,
  weekends, some days, every few hours, once) and sent as Hermes takes it (a cron expression in
  the server's time zone, "every 3h", a moment with its offset); one made elsewhere is kept as
  it is. Pause and resume, run now, change, delete. Hermes 0.21.5 and later fire a bot's on their
  own (the gateway ticks every profile's store); 0.21.0 and 0.21.3 only with
  `gateway.multiplex_profiles` on, and 0.21.3 also fails to run one as the bot ("No LLM provider
  configured", from the Dashboard's run-now): a schedule due five minutes ago that hasn't run
  says the server isn't running them (`BotRoutines.missed`). A run notifies a paired phone (plugin
  1.5.0, `routines.py`: no release has a hook for a cron run finishing, so every profile's
  `cron/jobs.json` is read each half minute and a job whose last run moved on is announced, with
  the answer from its saved output), a `routine` note that opens the bot's chat; a muted bot's
  don't come (`b:<profile>`). The Dashboard's login is needed: a bot added by its own key has no
  Bot Chat. `lab.sh routines` checks it all on the four releases. The Cron tab now uses the
  Dashboard whenever its login is kept, on either connection (it had the Hermes API's jobs routes
  then, without runs or blueprints), and acts on a job in its own profile's store (a bot's job it
  listed couldn't be paused or deleted from there).
- **Templates and tools** (asked 2026-10-20; `BotTemplate`, `BotToolsList`). New Bot starts from
  Blank or one of five templates (Researcher, Writer, Coder, Home, Planner), each a name, what it
  does, a personality, a face and the toolsets it needs, all changeable before it is made; picking
  another keeps a name the person typed. A bot's tools (its Tools row, in New Bot and Edit Bot) are
  the toolsets the server lists in `profiles.describe`, the main agent's by default (a new bot is
  a copy of it, so it has them without being told); a list of its own goes with
  `profiles.configure enabled_toolsets` after `profiles.create` (a template's, less any the server
  hasn't: no Home Assistant, no Home tools), and "Same as" the main agent sends the main agent's
  list as it stands. An empty list is never sent: 0.21.0, 0.21.3 and 0.22.2 take it for Hermes's
  own defaults, and 0.21.5 for no tools at all (measured). Fewer tools make a turn quicker to
  start on a model on the person's own machine. Hermes 0.21.5 and later keep a bot to its list
  (some behind `tool_search`), and the bot keeps `message_agent` and answers in group chats; 0.21.0
  and 0.21.3 take the list and give the bot every tool all the same, their Dashboard's chats
  reading the cli platform's toolsets, which only a whole-config write could change (the Tools
  screen says so). `lab.sh templates` checks it on all four releases; `HermesLabBotsTests` makes a
  bot from the Writer template with the app's own client. The main agent has the Tools row too
  (asked 2026-10-22, to take Code Execution off a butler that kept running server scripts
  itself): no "Same as", read and changed by the Dashboard's own switches (`GET`/`PUT
  api/tools/toolsets`, Settings → Agent → Tools', each that changed, only among those Edit Bot
  offers), which write `platform_toolsets.cli`, the list the Dashboard's chats and its Bot Chat
  read. Not `profiles.configure` as for a bot: 0.21.0 and 0.21.3 kept that list for the main
  profile where its chats never looked, and `profiles.describe` showed it, not what the chats had
  (measured). The Hermes API server reads `platform_toolsets.api_server`. The last switch on
  can't be turned off. Hermes fixes a chat's tools when its agent is built, so a change reached
  only new chats until the Dashboard restarted: after any tool change (Edit Bot or Settings →
  Agent → Tools) Redde sends `reload.mcp` with `confirm: true`, which gives every open chat its
  profile's tools again (and reconnects the MCP servers); 0.21.0's reload reconnects the MCP
  servers alone, so there it reaches chats started after it. `HermesLabBotsTests` takes Code
  Execution off the main agent and puts it back, no other switch moving, with a chat open that
  follows both (0.21.3 to 0.22.2).
- **Topology** (asked 2026-10-22, after another Hermes client's map; `BotTopology`,
  `BotTopologyView`). Topology, a tile beside New Bot in the Bots section's grid, opens a map: you at the top, the group chats
  under you, the bots under them with what each is doing (`ChatActivity`: working, needs you, a
  new reply, idle), and on the right the model each runs on (`profiles.list`'s `model`, on every
  release), one box for the bots that share it. You have a line into every bot (its own chat) and
  every group chat along the left-most lane; each group chat has a lane of its own into its bots;
  a bot's curve to its model is in its colour. `BotTopology` places the boxes and lines for a
  width (no overlaps, lines into one box spread apart; `BotTopologyTests`), the view draws them
  on a Canvas under the boxes, and a bot or group chat opens its chat. On the Hermes API alone
  there are no group chats and no models (the roster has neither), so it shows you and the bots.
  It reads the same directories as the list, kept fresh by the list's own watch.
  Handoffs (`BotHandoffs`, `BotHandoffStore`) are dashed arrows from one bot's right side round
  into another's, a step out each where they overlap (the column wider for them): a message one
  bot sent another (`message_agent`), read from the newest 150 messages of each bot's Bot Chat
  ("Message from …" that came in, and the answer that came back as a process notice), and a
  kanban card one bot made for another (`created_by` → `assignee`; "dashboard" is a person's).
  Hermes keeps no list of them. The chats are read with the Dashboard's read-only `GET
  api/sessions/{id}/messages?profile=…&order=latest` (no chat is opened for it, every release),
  or on the Hermes API alone at each bot's /p/<profile>/ with its key; at most once a minute.
  Hermes has no field for a bot that does its work through Claude Code (the butler setup's
  claude and research bots run Sol's model and call Claude Code from a tool), so
  `HermesBot.worksThroughClaudeCode` goes by what it says it does ("… with Claude Code"), or a
  profile "claude" on a model that isn't Claude's: a Claude Code box with a dotted line, beside
  its model's. Lab bots checks a real message's arrow on 0.21.0 to 0.22.2.
- **Making and changing bots** (`BotManagement.swift`, `BotEditor.swift`), as Hermes Desktop does:
  New Bot asks for a name, what it does, a personality (empty: one written from the name and what
  it does, Desktop's wording), a model, a face and its tools. The profile is made with `profiles.create`
  under a handle from the name (`BotNames.handle`: Hermes's rule for a profile's name, never a
  reserved word or one in use) and no command of its own on the server (`no_alias`; 0.21.0 makes
  one anyway), as a copy of the main profile, its keys and sign-ins included (`clone_from:
  default`, sign-ins shared), as Desktop makes one. Not without them: a custom endpoint is in the
  main profile's config.yaml with its key, so a profile made with none of it has no model it can
  reach, and Hermes takes no endpoint for a profile over the socket (a keyless bot is set up on the
  server). Then its name goes in its Bot Mode settings (`ui_meta['hermes-bots'].title` and `created`), and Hermes's
  `setup.runtime_check` says whether it can answer; a bot that can't is made all the same, with
  that said. Edit Bot… (its row's menu, or its chat's ••• menu) changes its name, what it does
  (the profile's description), its personality (SOUL.md, read with `profiles.describe`), its model
  (`profiles.configure`; a model Hermes asks about first is asked about here too) and whether the
  list shows it. Its Bot Mode settings are read, changed and written back with the revision read,
  three tries, so what Desktop keeps there (its colour, shape, sections) stays. Hide is on its row
  too; Hidden Bots at the end of the section shows them again. Delete Bot goes through the
  Dashboard's REST route (`DELETE /api/profiles/<name>`; there is no socket call): the profile,
  its chat and its memories go. The main profile is the person's agent: only what it does and its
  personality are changed here, and it can't be hidden or deleted. A profile's handle is never
  renamed (its folder, its sessions and Redde's saved chats are named by it); the name is what
  changes.
- **Bots messaging bots** needs one profile set up as a bot (an entry under `ui_meta` in its
  profile.yaml). Hermes Desktop sets that up when a bot is made or named there; without it, "Let
  bots message each other" at the end of the section writes an empty entry on the main profile
  (`profiles.configure`, compare-and-swap on its revision). Hermes then gives each bot's chat the
  tool and a list of the others; a chat begun before has the tool from its next message, but not
  the instructions about it. Ordinary conversations get neither.
- **What a bot is doing**, on its row as on a conversation's (`ChatActivity`): a spinner while
  Hermes runs a turn in its chat (`session.active_list`, which lists every profile's) or one of
  its workers (a kanban card it was given) was heard from in the last 150 seconds
  (`worker_session` in `profiles.list`, Hermes Desktop's measure); "Needs you" when the gateway
  says its turn waits on the person; a dot for something in its chat since it was last on screen
  here. Hermes lists no read mark for a bot's chat, so that last one is kept on the phone, by the
  bot (its chat's id changes as Hermes condenses it), against the chat's last activity; a bot seen
  for the first time counts as read. Mark as Read and Unread are on its row. While the list is on
  screen the bots are read again every 15 seconds.
- **Bots talking to each other** in a transcript (`BotMessages`, `Delivered` on a message): Hermes
  files what one bot sends another (`message_agent`) as a user row in the other's chat ("Message
  from 🤖 Scout (@scout): …"; 0.21.0 and 0.21.3 give the handle twice), and the reply comes back to
  the first as a background process finishing (`display_kind: process_complete`, the delivery's
  command naming the bot with `-p`, its output the reply: JSON from a chat held open in the
  gateway, plain words after any "⚠" warnings Hermes's command line prints from one run on its
  own). Redde shows the first as "Message from Scout", the second as "Scout replied", each with
  the bot's creature and its words in a quiet bubble on the bots' side, not as the person's; any
  other finished process as one line whose output opens on a tap; a `message_agent` step as
  "Messaged @scout"; and on a bot's row, the line "Scout: …". A turn Hermes starts for such a
  message in an open chat shows the message before the reply as it comes.
- `scripts/hermes-lab/lab.sh bots` checks all of it on each release: what Hermes does
  (`bots_check.py`), then the app's own client (`HermesLabBotsTests`), down to one bot messaging
  another with Hermes's own tool and both chats read back. Not on the Hermes API
  connection, whose bots would need the Dashboard's socket.
- **Group chats** (`ServerGroups.swift`, `GroupChatView.swift`): Hermes's hosted bot rooms
  (`groups.*`, the same methods on 0.21.0 to 0.22.2), listed under the bots with their members'
  creatures stacked, and made with New Group Chat (two to six bots). Hermes runs a room itself:
  a message goes to the bots it @tags, or to all of them, one after another; a bot that a reply
  tags may answer in turn, for three rounds or ten replies at most; one with nothing to add
  passes. A room's worker (`driver` in `groups.capabilities`) starts a moment after the Dashboard;
  without it a room can be read but not sent to. Hermes pushes nothing about rooms: the screen reads
  the room's log after its last entry (`groups.log`) and its state (`groups.state`: working,
  waiting, approvals) every second while bots are talking and every five otherwise, so replies come
  whole. Stop sends a fresh `cancel_id` each time (one used before stops nothing new); approvals in
  a room take "once" or "deny" (`groups.approve`), and one answered elsewhere or timed out is
  refused (5119) and the state read again. `pending_actions` of kind "retry" are replies Hermes
  lost track of (a restart mid-reply, a bot it couldn't reach): they get a Retry card
  (`groups.retry`). `blocked` means a stop or a recovery under way, never a question for the
  person. Lines about a bot's turn are written by Hermes as the gateway, with the bot in
  `payload.member_id`. End Group Chat disbands a room, tried again while its bots are still
  stopping. `lab.sh groups` checks it on each release.
- **Hermes Desktop's rooms** never go through `groups.*`: Desktop runs them itself, on the
  machine it is open on, and keeps a copy of each in the main profile's
  `ui_meta["hermes-bots-groups"]` (version 3: rooms keyed `id:<room>` with name, members and
  the last 16 messages of at most 1,200 characters, `omitted` for earlier ones, tombstones under
  `deleted`). Redde lists those rooms too, marked with a computer, and shows them read-only
  (`GroupRoom.desktopRooms(in:)`, `GroupFeed.lookInDesktop`): the copy read again every five
  seconds, its messages numbered by id (else time, author and text) so rows keep their place as
  the window moves. Nothing is written back: a message added to the copy would be merged by
  Desktop but no round would run for it. Likewise Desktop never shows rooms made in Redde.
- **The room's screen** is a plain stack, not a lazy one, holding the newest 30 rows, with Show
  earlier for the rest (the first row shown is kept by its number from the front, so a message
  added at the end never takes rows off the top). It is anchored to the bottom when it opens,
  and on changes of size only while the end is in view. A new message is followed only from
  the end. The feed writes members, state and problem only when they changed: each write
  redraws the room, every second while bots talk. Lazy rows and a blanket bottom anchor made it
  jump about when scrolled, as the transcript's once did.
- **Replies as they are written.** Hermes writes a bot's reply to the room's log only once it is
  finished (`message.member`, the whole text at settle), and pushes nothing about rooms. It runs
  each bot of a room in a hidden session on the bot's profile titled `Group: <room>`, and keeps
  every session's last 512 events for a client that reconnects. While the room is at work, the
  feed reads them twice a second (`GroupFeed.lookAtDrafts`): `session.active_list` gives the
  room's sessions at work, `session.events.since` their events after the last one read
  (`GroupDraft.read`: a reply starts over at `message.start` and at `message.interim`, grows by
  `message.delta`, is whole at `message.complete`), and `session.list` on each bot's profile, by
  that title, says whose each session is. The reply shows as the conversation's live one does,
  under its bot, until the room has the bot's message. The sessions are never resumed or
  activated: either ties a session to the phone, and Hermes puts away a session whose phone has
  gone, mid-turn. They are in the Dashboard's list only while its process runs the room (each
  room is leased to one process, and Hermes's gateway runs rooms too); otherwise replies show
  when finished, as before. `lab.sh groups` checks it on each release with a reply the stub
  streams a word a second.
- **The conversation's tools.** A room's field is the conversation's, made smaller
  (`GroupComposer`): Add (Files, the photo library, the camera), the pictures and files waiting
  to go, dictation, and Talk in an empty field. A room takes text alone (`groups.send` refuses
  any field but `text` and `thread_id`, on every release), so what is attached goes to "Redde
  attachments" in the server's home through the Dashboard's file manager (`ServerFiles.place`,
  shared with the Hermes API's files) and the message names it in a note (`AttachedFileNote`, "a
  picture … look at it with your tools" or "a file … read it with your tools"): a bot opens it
  with its own tools (Hermes's vision tool takes a local path). Redde hides the note and shows
  the files under the message, fetched from the server on a tap. Bots' replies have the
  conversation's copy, read aloud, share and select; Find in Chat looks through the whole room,
  earlier pages too. Talk opens the voice screen on the room (`VoiceView.group`, a
  `GroupVoiceScene`; asked 2026-10-20), hands-free (`GroupVoice`): the voice session hands what
  is heard to the room (`VoiceSession.sendsTo`) instead of the conversation, each bot's reply is
  read aloud as it is written (asked 2026-10-20: the bots had seemed slow, but it was the wait for
  each whole reply), from its live session (`GroupDraft`, through `VoiceSession.beginReading` /
  `continueReading` / `endReading`), or once it lands where replies aren't followed live, one
  after another in the order they began, in that bot's voice (`BotVoices`), and the mic opens
  again once the round is over, unless a bot waits on the person (then the screen says to answer
  in the chat). `GroupReplies` (pure, `GroupRepliesTests`) decides what is read: each reply once
  (a draft and its message are one), none from before voice began, never a bot passing (Hermes
  takes "pass", "(pass)" or "Pass." as silence on every release, so a draft waits until it can't
  be one), a reply stopped midway cut where it got and one not begun dropped; a reply written
  over (the words beside a tool call, which the room's message leaves out) carries on with the
  new words. While one is read, the next one's first sentence is fetched from Kokoro
  (`SpeechOutput.prefetch` → `KokoroPlayer.prefetch`, kept through the stop at the next reply's
  start and taken by the `enqueue` asking for the same words, voice and speed), so the next bot
  starts when the one before ends. In the orb's place are all the room's faces while none speaks (`GroupVoiceFaces`,
  up to six, level round the centre: two side by side, three as two over one), and the one being
  read while it is, handing over to the next as the voice screen does between bots; the header
  is the room's faces and name, the status says who is speaking or writing, the captions are the
  round so far (the person's last message and the replies after it, drafts as they are written),
  and Replay reads the last reply again in its bot's voice. Tapping the mic while a reply is read
  listens at once; the replies not yet read stay on screen. The red Stop (`GroupVoice.halt`) ends
  the reading, the listening and the bots' round if one is going (as the chat's Stop), and holds
  the mic shut until the orb is tapped: without the hold, the quiet session read as the round's
  end and the mic opened again, so Stop never stopped. Once stopped it is the ✕ that leaves.
- **Notifications** (asked 2026-10-20, plugin 1.4.0; `docs/push.md`, "Group chats"). A paired
  phone hears of each bot's message in a group chat it follows, and of a bot waiting on the
  person there, also with Redde closed: the plugin reads the rooms' own log (no Hermes has a hook
  for it) and the Dashboard's room service, and sends `group` and `group_wait` notes (`PushNote`:
  `g` the room, `t` its name, `d` the bot). The app follows the hosted rooms it lists
  (`GroupDirectory.refresh` → `PushService.followRooms`, a `rooms` command over the Dashboard,
  each launch and whenever the list changes); Hermes Desktop's rooms aren't on the server. On the
  phone they read as a group chat's do in Messages (the room, then the bot, then the words,
  stacked per room); a tap opens the room in the chat's place (`LaunchRouter.requestRoom`);
  Reply says the words in the room, Approve or Deny answers the command whose digest the note
  carries, found in the room's state (`Notifier.routeGroupNote`; one no longer waiting says so),
  and Retry runs a turn again. One about the room on screen isn't shown over it. Group chats are
  the Dashboard's, so this needs its login on either connection; an older plugin answers `rooms`
  with its usage line, and Settings offers to update it (`PushPlugin.version`). `lab.sh grouppush` passes on 0.21.0, 0.21.3,
  0.21.5 and 0.22.2.
- **Mute** (asked 2026-10-20; `Mutes`, `MuteMenu`). A bot's chat or a group chat is muted from
  its row's menu or the chat's ••• menu: for an hour, eight hours, until eight tomorrow morning,
  or until turned back on (`MuteSpan`), kept per server by the row's id (`Settings.mutes`,
  synced). A muted row wears a crossed-out bell and no unread dot; that it works or waits on the
  person still shows. Its notifications stop where they start: the plugin is told what is muted
  and until when, as sessions ("s:<id>": a bot's chat on the roster and any the phone keeps for
  it, on either connection) and rooms ("g:<id>"), over the Dashboard (`PushService.sayMutes`,
  `mutes <devices> <key=until,…>`, plugin 1.4.1), and leaves those phones out. What comes anyway
  (a Hermes API turn notifies every paired phone, and there is no Dashboard to tell without its
  login) arrives quietly, in the list only: the app writes the same keys to the app group
  (`MutedChats`), which the notification extension reads, and the app's own banners and those
  arriving with it in front follow it too. Hiding a notification outright would take the
  filtering entitlement. Published again when a mute changes, when the server's bots are read
  (Start Fresh gives a bot's chat a new session) and when the app comes forward.
- **Faces in a grid** (2026-10-21/22, a Reddit suggestion and his picks). The chat list shows the bots
  as faces with their names under them, five to a row, with no sideways scroll (`botGrid`).
  - New Bot (Add Bot on the Hermes API alone) and the hidden ones come after the bots. The group
    chats are rows under the grid.
  - More than six bots fold to one row: four faces and "N more". A small Fewer button under the grid
    folds them again, and the choice is kept (`sessions.botsExpanded`).
  - Each face is a `Menu` with a primary action: a tap opens the chat, a long press opens its menu.
    A `.contextMenu` inside a List row opened the row's first menu, whichever face was pressed.
  - `-echo.demoBotCount n` adds bots to the demo roster.
- **Order.** Bots and group chats are one run in the Bots section. Reorder Bots, in any of their
  menus, shows only them, with handles (edit mode; outside it a long press is the row's menu,
  which a drag can't get past), and the order is kept per server in `Settings.botOrder`
  (`BotListItem` ids, synced by iCloud): a bot renamed keeps its place by its old name, and one
  new since goes at the end. CarPlay's Bots tab and the watch follow it. Sort Bots by Recent
  forgets it.

**On the Hermes API connection**, two ways (`BotDirectory.reachable`, `.apiOnly`):
- With the Dashboard's address and login saved too, everything here is there as on the Dashboard
  connection: the roster, faces, New and Edit Bot, group chats, live replies, marks. A bot's chat
  goes by the Dashboard (`Conversation.connection`: the app's connection, except a bot's chat),
  as Kanban, Files and phone tools already do on the API: a bot is a profile of its own, which
  the API serves only with that profile's own key. Its approvals, questions and Stop go that way
  too; the app's own conversations stay on the API.
- With no Dashboard login, bots are added on the phone (Add Bot, `APIBot`): a profile by its name,
  tried before it is kept, kept per server and synced with iCloud. Hermes takes the
  `API_SERVER_KEY` in the profile's own `.env` at `/p/<profile>/` and never falls back to the main
  one's; 0.21.0 copies it into a clone, 0.21.3 and later leave it out (with the messaging
  channels), so it is put there by hand, at once in effect. The main key is tried first, so a
  profile given the main key needs only its name; one with a key of its own is asked for it, kept
  in the Keychain beside the profile picker's. Its chat is the profile's "Bot Chat" at `/p/<profile>/` (found by title, made
  the first time; the same session the Dashboard and Desktop show), and goes as any API chat does:
  runs, approvals, a run left asked after and taken up again by the bot's own address
  (`ChatActivity.LeftTurn.profile`), Start Fresh by archiving it. Hermes 0.21.5 and later serve
  every profile at `/p/<name>/`; 0.21.3 and earlier only with `gateway.multiplex_profiles: true`.
  The API lists no profiles and keeps no faces, so there are no faces picked on the server, no
  New or Edit Bot, no @mentions, and no group chats. `lab.sh apibots` checks it on each release,
  and `lab.sh bots` the first way.

**Voices.** A bot reads its replies in a voice of its own (`BotVoices`, `BotVoicePicker`): in voice
mode in its chat, Read aloud, a group chat's Talk, and the car. The voice session says whose words
it speaks (`VoiceSpeaking.speaker`: the conversation's bot, set again after a spoken prefix moves
there, or whoever Read aloud names), and `SpeechOutput` reads them in that bot's voice: one picked
for it (Voice… in its row's menu, its chat's ••• menu and Edit Bot; kept per server in
`Settings.botVoices`, synced), else Automatic, one of the voices Redde reads with now in the
language of Redde's voice and never Redde's: the Kokoro server's (British and American both
count as English), or the built-in ones installed (enhanced and premium first, then the others,
novelty voices never), given out by name (FNV-1a) through the roster in name order, so no two bots
share while there are voices enough. "Same as Redde" reads in Redde's own; the main agent always
does. A reply clearly in another language still goes to a voice for it. Hermes's own voice is
the server's, one for every bot.

### Incognito chats

New Incognito Chat (the chat's ••• menu, ⇧⌘N) opens a conversation kept nowhere
(`Services/Incognito.swift`, `Conversation.isIncognito`), on both Hermes connections. It isn't
saved on the phone or listed; its words stay off the Lock Screen (Live Activity and background
task say "Incognito chat"), the Last reply widget, notifications ("Your reply is ready.") and
Siri's donations, and the Dashboard isn't asked to push about it. On the Dashboard its session is
made `hidden`, so no app lists it while it lasts; on the Hermes API, which has no such flag,
Redde leaves it out of its own list. Hermes has no switch for one session's memory, so the agent
is told the chat is incognito and to save nothing from it: in the turn's instructions on the API,
in a note on each message on the Dashboard, which Redde hides (`IncognitoNote`). Leaving it (New
conversation, another chat) stops a reply still under way and deletes its session from the
server, closed first on the Dashboard, which refuses to delete a live one. Its session is noted
from the moment it has one (`Incognito.Pending`), so one the app couldn't delete as it was left
(closed, the server away) is deleted when Redde next comes forward. Rename, Add to Project and
the like aren't offered in it. `lab.sh runs` checks both connections on each release.

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
stop it (`subagent.*` events). On the Hermes API a run sends the same events (the chat stream
didn't, and rows there were built from the delegate call's goals). The API doesn't serve a child's
session (404), so its transcript is read through the Dashboard when its login is saved, again every
three seconds while it works; a child of an API turn runs in the gateway, so it can't be steered or
stopped from the Dashboard. `Views/SubagentRows.swift`, `SubagentTranscriptView.swift`.

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

On the Hermes API, which takes text and pictures, any other file (a PDF, a video, anything) goes to
the server through the Dashboard when its login is saved: into "Redde attachments" in the server
user's home, named with the time it was sent (`Conversation.placingFiles`). The message then says
where it is, for the agent to read with its own tools (`AttachedFileNote`, hidden when the message
is shown again; the API doesn't expand `@file:` references as the Dashboard does). Without the
login it is refused, saying so.

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

The other way round, a reply delivers a file by naming it: a line `MEDIA:/path/on/the/server`,
a Markdown image of such a path, or "[IMAGE: /path]" (`ServeMedia`, `Shared/ReplyMedia.swift`).
After a turn the app fetches each over the Dashboard's file API (`/api/fs/read-data-url`, so it
needs the Dashboard login, also when the conversation runs over the Hermes API), attaches it
and takes its path out of the text; one that can't be fetched stays in the text, and is shown
as a file to open (`DeliveredFileChip`: fetched on a tap through `/api/fs/download`, with no size
limit, or saying why it can't be: no Dashboard login, not on the server, refused). Since
2026-10-21 (a Reddit report: an agent's Markdown files never reached the chat) a `MEDIA:` tag is
read as Hermes's desktop app reads it: quoted, with spaces up to a known extension, from `~/`,
relative to the session's folder (the Dashboard is told `session_id` for those, Hermes 0.21.3
on), any kind of file. The Hermes API's hint (`HermesSessionsTransport.clientHint`) teaches every
kind of file, not just pictures. A Markdown file opens as it reads (`FileViewer`,
`MarkdownDocument`), anything else in Quick Look, under Done. An agent that only says where it
left a file ("I saved it to /home/…/sample.wav", a Reddit report 2026-10-22) gets the path made a
link once the reply has finished (`ServeMedia.linkingPaths`, through `MarkdownView.linkPaths`):
absolute, `~/`, `./` or relative paths ending in a kind of file worth handing over (Hermes's
delivery list and the kinds the chat shows, not code), in running text or as a whole code span,
never inside code blocks, links or web addresses. Nothing is fetched until a tap; the tap
(`OpensServerPaths`) fetches as `DeliveredFileChip` does and opens it, or says why under the reply.

`::preview{file="page.html"}` (the desktop app's in-chat page, taught to Dashboard chats by
Hermes's own desktop hint since 0.21.0, and to Hermes API chats by Redde's) is a web page the
agent wrote, shown live under the reply's text as the desktop app shows it
(`inline-preview-directive.tsx`): `AgentPage` in `Echo/Views/AgentPages.swift`. Fetched like any
named file, it is kept as an attachment with its server path (`Attachment.page`). It runs in a
web view of its own, nothing stored, links opened outside, the main frame never navigating away;
the app's colours come first as `--foreground`, `--muted-foreground`, `--accent`, `--border` and
`--card` (after the doctype, so the page keeps standards mode, with a phone viewport when the page
names none); a script in a world of the app's own reports the content's height (120 to 1200
points, scrolling past that) and, once, its width, so a widget of a set size sits left like a
picture. `window.hermes.send(prompt)` and `data-hermes-send` reach the app through a handler in
the page's world that answers with the desktop app's acks (`PageIntent`: 500 characters, one a
second, refused with the reason, never cut). The prompt goes as a turn of its own with no message
of the person's (`Conversation.sendFromPage`): `prompt.submit` with `display_kind: "hidden"` on
the Dashboard (every release from 0.21.0 takes it), and on the Hermes API, which has no hidden
messages, the text marked `[From the page in the chat]`, which a reopened chat leaves out
(`PageTurn`, `BotMessages.userMessage`). The agent answers by writing the page again; the page is
read again when its turn is over (`refreshPage`). Not while a reply is still coming, never as the
first message of a conversation, and not on the fast lane; the page is told, and a toast says
why. Lab `files` checks both connections (`aPageTalksBackUnseen`); `-echo.demoPage` shows one. Pictures and documents were fetched from the start. Sound
was not, and a spoken reply from the agent's speech tool stood there as its path (reported
2026-10-12): it is now, by its ending (mp3, m4a, aac, wav, ogg, oga, opus, flac, aiff, caf),
along with the tool's `[[audio_as_voice]]` line, which goes. Stock Hermes writes MP3, and
Opus in an .ogg for platforms with voice bubbles; iOS 27 decodes both, and FLAC, WAV and AAC
(checked in the simulator; iOS 26 not checked). A sound attachment is a file like any other to
the server (`Attachment.isAudio`, by type or by name) and is shown as a player where it stands
(`AudioBubble`: play or pause, a bar to move along, the time; `AttachmentAudio` plays one at a
time through the playback audio session, like a reply read aloud). One the phone can't decode
is a file chip that opens in Quick Look. Read aloud, the tag is "audio attached", never a path.
A chat opened again from the server comes back as text, its files bare paths once more,
pictures included: the newest eight replies that name files have them fetched again, newest
first (`Conversation.resolveReopenedMedia`). `-echo.demoAudio` shows a reply with a sound to
press. Tried with a stand-in for the file API (`EchoTests/ReplyAudioTests.swift`) and in the
app with a tone made on the spot (`ReplyAudioUITests`). A file from a real Hermes played on an
iPhone on 2026-10-12; a reopened chat getting its player back has not been seen on a device.

Bytes are stored one file per attachment under Application Support (file-protected); transcripts
keep metadata only. The share extension (`EchoShare`) writes to the App Group
(`group.com.goosehouse.echo`); the app turns shared items into a draft on its next foreground.
The share sheet's "New conversation" switch (remembered in the App Group's defaults) puts that
draft in a new conversation instead of the open one, and Settings → Siri → "Drafts in a new
conversation" does the same for Siri's "draft a message" (GitHub issue 21). `ContentView`
hands the composer to the new conversation before the text goes in (`startFreshForDraft`):
the per-conversation draft follows a change of conversation only on the next update, which
would otherwise leave the text with the one being left. Not when the open conversation is
empty, and not on the fast lane while a reply streams. `-echo.share`, `-echo.shareNew` and
`-echo.siriDraft` bring one in at launch (`NewConversationEntryUITests`).

A drop anywhere on the chat goes to the composer too (`DroppedItems` sorts it, `ChatDropTarget`
is the modifier on the chat): pictures and files join what is waiting to be sent, a link or a
dragged selection goes on the end of the draft. A text file out of Files and a sentence out of a
web page can register the same types; what tells them apart is whether a file stands behind the
item, so one is attached and the other typed. The providers' callbacks come on queues of their
own and are made in nonisolated helpers for that reason. `-echo.dropHint` shows the outline a
drag brings up, since the simulator can't drag between apps.

"Select text" in a reply's menu (and in your own message's) opens a plain copy of it that
selects by the word (`SelectableTextSheet`, a `UITextView`: SwiftUI's selectable `Text` has no say
in the selection's menu). The transcript's own text isn't selectable: each selectable paragraph is
a UIKit text interaction with its menus, built as a conversation opens and torn down as it
closes, and that was half of what opening a long one cost (2026-10-21, `MarkdownView.selectable`).
In the transcript that menu starts with "Ask about this", which closes the sheet and puts
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

A conversation on the Dashboard can be put in a project from the chat's ••• menu (Add to Project,
or Move to Project when it is in one; New Project… makes one and moves it there), as the chat
list's Move to Project does (`ChatProjectMenu.swift`, the projects kept in `ProjectDirectory`).

On the Hermes API a conversation has fast mode only (`RunChatControls`): the API keeps no switch for
a session, so the phone keeps it, by server and conversation, and each run asks for the fast tier
(`model_options.fast`, every release). Hermes passes it on only to a provider that bills for it; a
turn on any other model runs as usual. There is no way over the API to run commands without asking.

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
Dashboard), and **New Project…**, which makes one and moves the conversation into it. The Home
bucket is no folder, so nothing can be moved back into it from here.

**Projects of your own** (`ServerProjects.swift`) are Hermes's named projects, the ones Hermes
Desktop lists (`projects.create`, `projects.update`, `projects.delete`, per profile). Redde makes
one over a folder of the same name in the server's `~/Projects`, made with the file manager's
`POST /api/files/mkdir` if it isn't there (an existing folder, a repository say, is used as it
is; a hosted install that keeps its files to one folder gets its Projects folder inside that).
The name loses what a path can't hold; renaming keeps the folder; removing takes the project off
Hermes's list and leaves the folder and the conversations, which then belong to no project. A
second project over the same folder is refused by Hermes, and said in the app's words.

A conversation starts in a project from **New Conversation** on the project's screen or its row's
menu, or straight after **New Project**: `Conversation.startNew(in:)` keeps the project as
`startsIn`, and the first turn's `session.create` carries the folder as `cwd`; later turns have
the session and no folder. The chat's header names the project beside the folder glyph: Hermes
says which project owns a session's folder in its `info` (`project.name`, null for none), which
`ChatControlStore` files with the switches; until it has, a new conversation shows the project it
was started in. Moving, renaming or removing asks the server again for the open conversation, so
the header follows.

All of this is the same in Hermes 0.21.0, 0.21.3 and 0.21.5 (`lab.sh projects` checks the
projects with the app's client). `scripts/hermes-lab/lab.sh controls`
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
and repo: the ones someone made (`isAuto: false`) even before their first conversation, the ones
Hermes found (repositories conversations ran in) once they have one, then a **New Project** row. Search, pin, rename, fork, archive and delete go through `PATCH /api/sessions/{id}`, fork
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
to move a card, edit, comment, and ask Redde about the card, in a new conversation or the open
one (GitHub issue 21; a Hermes turn under way in the one left goes on). Moving to Blocked or Scheduled asks
for a reason, Review or Done for a summary. It updates live over the plugin's events socket and
falls back to polling. A card with a patch on it (Hermes's card attachments: the claude bot's
plugin attaches its change, and any notes of steps that need a key, as it finishes) has View
Changes, the change as a diff (`PatchView`: each file with what it adds and takes away), and, once
done, Ask … to Apply It, which asks the agent in a new conversation to put it in place with its own
tools (so whatever asks before a write asks then). An approval that names a card (`t_…`, as the
agent putting that work in place does) has View Changes too, to look before answering.
`Services/HermesAutomation.swift`, `Views/CronView.swift`, `Views/KanbanView.swift`.

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
how much conversation there was when `following` went off and compares. The pill is there only
while the end is out of reach (`offersJump`): it goes the moment the end comes up under a
scrolling finger, and a touch at the end does not bring it out. Following itself starts again
once the scrolling has stopped at the end, so text that arrives under a finger does not pull
the transcript along.

Whether the transcript is at its end comes from the scroll view's own account of itself
(`TranscriptEnd`, 120 points of reach). That account is easy to misread: `containerSize` is the
room between the bars and `contentOffset` is where the scroll view begins behind the top bar,
so what can be read ends at offset + top inset + room. Until 2026-10-13 the sum was made as if
the room still had the insets in it and came out short by both of them, about 214 points with a
navigation bar and the composer, which is more than the reach: the end never counted as
reached by hand, "Jump to latest" stayed on screen there, and new text was not followed until
the pill was tapped. (Tapping it always worked, which is all the UI tests had tried.) Measured
the same on iOS 26.3 and 27.0; `EchoTests/TranscriptEndTests.swift` holds the sums with those
numbers and `TranscriptJumpUITests` scrolls back to the end by hand.

### Arrivals and openings

- **A message you send rises out of the composer** (`MessageArrival`): its row starts below its
  place, behind the field, and comes up into it, and the reply's waiting row holds back a beat so
  the two don't cross. One move of offset, scale and opacity on one row, decided by the message
  being under a second and a half old, so a conversation that loads doesn't move. A message
  held behind a running reply arrives in the queue the same way.
- **A picture or a diagram opens out of its thumbnail** and closes back into it: the system's
  zoom transition (`matchedTransitionSource` on the thumbnail, `navigationTransition(.zoom)` on
  the full-screen cover), in `PhotoGroup`, `MarkdownImage` and `MermaidBlock`. It brings
  the drag-down and pinch to close with it.
- **A message's pictures stand together and open as one set** (asked 2026-10-13, after Messages).
  One picture is shown at its own shape; two side by side, three as one large and two small,
  four as a square of four, and from five on the fourth tile says how many more there are
  (`PhotoCollage`, `PhotoGroup` in `Attachments.swift`). Files and videos are tiles under them.
  A tap opens `PhotoViewer` on the picture tapped, with the rest a swipe away, "2 of 5" at the
  top, a pinch or a double tap to zoom, a drag to move about a zoomed picture, a tap to clear
  the screen of everything else. A picture in a reply's text (`MarkdownImage`) opens in the
  same viewer on its own. Three things in it are UIKit's on purpose, each found with
  `PhotoViewerUITests`:
  - The zooming is a scroll view's (`ZoomingPictureView`). The system's pinch for closing a
    view that opened out of a thumbnail takes a pinch away from a SwiftUI gesture, which is why
    pictures never zoomed before; it gives way to a scroll view that can still zoom.
  - The pages are a row in a scroll view written out here (`PhotoPagerController`). A SwiftUI
    scroll view that pages opened on the first picture whichever it was told to show. UIKit's
    page view controller keeps one page in its scroll view until a drag is under way, and the
    system closes the viewer on a swipe back (a drag to the right) unless a scroll view under
    the finger has somewhere to go that way: going to the picture before closed the viewer or
    did nothing. With every page in its place from the start the system can see there is one
    before; on the first picture a swipe back closes the viewer, as anywhere in iOS.
  - While a picture is zoomed a do-nothing recognizer takes every drag, and the system's
    closing gestures have to wait for it to fail, so a drag that reaches the picture's edge
    does not close the viewer.
  The pages showing and beside it hold their pictures, decoded off the main actor at up to
  4,096 pixels; the others hold nothing. `-echo.demoPhotos [n]` seeds a conversation to try it on.
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
fresh conversation each time the voice screen is opened from outside the chat (Siri, the Action
Button, a control, opening Redde), before it appears, and also while the last conversation is still
loading at a cold launch; the waveform button and ⌘⇧V carry the chat on (GitHub issue 14). A turn ends after about a second of silence; hands-free reopens the mic after each reply.
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

One orb is no picture: **Redde** (`ReddeVoiceFace`) is Redde's own bot face, its bubble in the
theme's bubble colour (or the one picked for it), glowing along its outline in the phase colour.
It has no bars or light; its
eyes say what is happening instead. It blinks about every four and a half seconds (now and then
twice); at rest it holds a look, then glances quickly to the next; while you talk it looks at you;
while it thinks it looks up and away, its eyes circling; while the reply is read out its mouth opens
with the voice's level. It leans a little the way it looks. One pose a frame from the time and the
phase (`BotPose`), no breathing, and still under Reduce Motion.
- **Rings** outside the face: one in the phase colour while something is happening, with a bright
  arc chasing round it while thinking (`ThinkingArc`), and ripples widening out while listening
  and speaking, one faint one every few seconds at rest (`Halos`).

Redde's own face is the default, and first in the picker. Every orb has live bars; the still
ones were removed, and a saved still choice falls back to the default. **Dark Glass** is the one orb drawn in code rather than from a picture (`GlassOrb`,
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

Replies are spoken sentence by sentence while they stream, by AVSpeechSynthesizer, a Kokoro server
or the user's Hermes (Settings → Voice: On-device, Kokoro, Hermes; `Settings.replyVoice`, which
took over the old Kokoro switch). Kokoro: one PCM streaming request per sentence, decoded ~100 ms
at a time onto an `AVAudioPlayerNode`, fetched ahead and played in order, with the built-in voice
as the fallback. Measured 2026-10-20 on a 64 GB Mac (Kokoro-FastAPI 0.7.2-rc1 on MPS, the same
GPU as the agent's model): a 5-second sentence in ~0.45 s alone and ~0.85 s while the model writes,
and about a second more the first time a sentence of a new length is made (MPS compiles a program
for each input shape). Left running for days that server grew to 26 GB (19 GB compressed), and one
request in five stalled ~7 s while it was unpacked: 0.7.2 never empties the MPS cache (its memory
check is CUDA's only), and the compiled programs pile up besides, so it wants a restart now and then. The replay button speaks the last reply again without a new turn. The speech model
is downloaded in the background at launch.

**Hermes's own voice** (GitHub issue 7, `Services/Voice/HermesSpeech.swift`). The Dashboard speaks
with whatever `tts:` in Hermes's config.yaml names (Edge by default, ElevenLabs, OpenAI, Gemini,
xAI, a command or a voice running on the server), so the phone holds no voice key. The same player
plays it, a sentence at a time: each one opens `api/audio/speak-stream` (a ticket, as the Kanban
socket does, and `?profile=`), sends `{"text", "done": true}` and gets back a start frame with the
sample rate, 16-bit mono PCM, and an end frame. `PCMStream` turns that into the player's 24 kHz,
converting another rate (22.05 kHz from Piper; whatever an OpenAI-compatible server reports on
0.22) and dropping a WAV header an OpenAI-compatible server may send for "pcm". A voice with no
streaming API makes Hermes up to 0.21.5 answer `fallback` at once; 0.22 speaks such a voice a
sentence at a time itself and says fallback only when that made no sound (Edge's MP3 with no
ffmpeg on the server). Then `POST api/audio/speak` speaks the sentence whole, as a data URL of MP3
or WAV, and the Dashboard is remembered as whole-only for ten minutes so later sentences skip the
socket. A sentence stopped partway closes its socket, which stops Hermes too. Speed and language
are Hermes's settings, so Settings hides those rows for this voice; Settings' "Say a test
sentence" asks for a sentence whole, because that answer names the provider ("Spoken by
ElevenLabs", "Edge, Microsoft's online voice"). The Hermes API server has no speech routes
(`audio_api: false`), so this needs a Dashboard address and login, whichever connection the chats
use; without one, the built-in voice reads replies. The watch keeps its own voice. Checked against
real Hermes by `lab.sh speech`.

**Which transcriber.** `Transcriber` picks the SpeechAnalyzer module by the device:
`SpeechTranscriber` where `SpeechTranscriber.isAvailable` says so, and `DictationTranscriber`
where it does not. An iPhone 11 or SE 2 is such a device (the newer one knows no language there,
which Redde used to report as a problem with the user's language), and so is the simulator.
`DictationTranscriber` is the model behind keyboard dictation; it runs on the device too, needs no
speech-recognition permission, and gives tentative text as the words come, which endpointing
reads. It punctuates less and gives one final result per utterance. `-echo.dictation` listens with
it on a device that has both, and `SpeechRecognizerTests` runs each test with each of the two; in
the simulator both skip (it calls the dictation model installed and then has no audio format for
it), so a run on a device or the Mac is what tests them.

**Languages.** Settings → Voice → Listening language picks what the transcriber listens for
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

**Showing it something.** The camera button beside Hands-free on the voice screen
(`VoiceSession.setLooking`) opens the back camera, and the orb's place shows what it sees
(`Viewfinder`, `CameraPreview`): the same size, the same tap to listen and to stop, the phase
colour on its edge and the bars along its foot. While it is open, each question asked goes with
one picture, taken as the question ends (`VoiceSession.handleUtterance`): a frame of the running
video (`CameraFeed`, 1080p, no shutter and no sound), stood upright by the angle iOS gives for
the way the device is held (`CameraStill`), and sent as any attached picture is, so the model has
to be one that sees. The picture stands with the question in the conversation. Stop and a
finished reply leave the camera open for the next question; leaving the voice screen closes it,
and it is never open when the screen comes up. A note taken by voice takes no picture. A frame
more than a second old is not sent: iOS takes the camera away when the app leaves the screen,
and what it saw before is not what it sees now. `VoiceLooking` is the seam; `-echo.voiceLook`
puts a made-up camera there for the simulator, which has none (`VoiceLookTests`,
`VoiceLookUITests`). Not run on a phone yet: the real camera's picture, the preview, and the
camera beside voice mode's microphone are all to be seen there.

**Answering a request aloud** (Settings → Voice → Answer requests by voice, off until turned on).
When a turn that voice mode started stops on a command to approve or on one question from the
agent, `VoiceSession.ask` reads it out after whatever of the reply is still being said
(`SpokenRequest.prompt`: what the command is for, the command cut to a line, "Say approve, or
deny"; or the question and its choices by number), then opens the mic for the answer. An answer
is the whole utterance and one of a short list (`SpokenRequest.answer`): "approve", "yes", "go
ahead" on one side, "deny", "no", "cancel" on the other, a choice by its number or its own
words, or for a question without choices whatever is said. It is said back ("Approved.") and
sent the way the card's buttons send it, and the reply carries on. Anything that is no answer,
silence for twelve seconds included, gets one reminder and is then left for the screen with
"It's waiting for you on your iPhone", which is also where the car's card goes ("Needs your
phone"); nothing is approved because it sounded like yes. A request settled some other way
meanwhile (its card, its notification, the host's time limit) shuts the mic at once. A password,
a secret, several questions at once and a question that takes several answers are never asked
aloud. A tap on the mic while the request is read out means "I'll answer now" and does not end
the turn, as it would end a reply; the car's Pause at that point leaves the request for the
phone. The mic behind a reply (below) is closed first: a "yes" said over the request would
otherwise count as talking over a reply and end the turn. Tried with scripted turns in
`EchoTests/SpokenRequestTests.swift`; not yet with a microphone, a real agent or a car.

**A nod or a shake** (Settings → Voice → Nod or shake to answer, offered with the switch above
and off until turned on). With AirPods that sense movement, a nod approves and a shake of the
head denies; for a question, only one whose two choices are a yes and a no
(`SpokenRequest.answer(nod:)`). `HeadGestures` reads the AirPods through
`CMHeadphoneMotionManager` and `HeadGestureDetector` tells the gestures from the rest of what a
head does: three swings in a row, down, up, down, each at least 6° and no slower than 0.7
seconds, and mostly in its own direction. One nod is not enough, nor is a look down at the
phone and back, the bob of a walk, or a head that rolls or moves on a slant.
`VoiceSession.watchHead` reads the AirPods from when a request starts being read out until it is
settled, at no other time, and only when the reply plays through headphones; `headMoved` takes a
gesture for an answer only once the request has been read and the mic is open, so a nod along
to the reply, or to the request while it is still being read, answers nothing. The answer is
said back like a spoken one. Saying it works alongside, and whichever comes first counts. iOS
asks for Motion & Fitness when the switch is turned on (`HeadGestures.askToSense`), not in the
middle of a conversation. The movement is used where it is read and kept nowhere, except that a
DEBUG build writes what the AirPods reported while a request waited to
`Library/Application Support/head-motion.csv` in its container: the detector's numbers are
estimates of how a head moves, and that file is for setting them from a real one.
The detector is tried on drawn movement and the conversation on a stand-in for the AirPods
(`EchoTests/HeadGestureTests.swift`); nothing here has run with AirPods on a head, which the
simulator can't stand in for.

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
Playing app, so a stem press or play-pause does what the mic does, except while the agent works
on a reply: the Lock Screen has the turn's Live Activity and iOS's "is working" card then, and
Redde gives up the player until the reply is spoken. Removing the headset stops speaking. "Announce on AirPods" makes alerts time-sensitive so Siri can read them.

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
While a Dashboard conversation is open and nothing is being followed, the app also watches its
session for a turn the host starts in it itself (`HermesTransport.watchHost`): a kanban card the
agent made, finished, wakes it there, or a bot's reply comes back to it. The first event only a
turn sends (`message.start`, text, a tool, a question) makes the conversation join it as opening
would, so a question it asks before a command gets its card at once; before, the card came only
when the chat was next opened, and an unanswered approval times out into a refusal. A question
asked before the join is put again from the session's open requests (`replayOpenRequests`,
`includingKnown`). Checked with the app's own conversation by `lab.sh butler --app`
(`HermesLabButlerTests`), which fails without the watch.

**Leaving a conversation while the agent works in it** (opening another one, or starting a new
one) lets go of the turn without stopping it, on both Hermes connections (GitHub issue 12): the
Dashboard's turn is not sent `session.interrupt` (`TurnDeparture` on the request tells the
transport it was left, not stopped), and Hermes finishes it and records its reply
(`scripts/hermes-lab/lab.sh switch`). Coming back, the Dashboard joins the turn if it is still
under way.

**On the Hermes API every turn is a run** (`HermesRuns`, from 1.10), because Hermes stops the chat
stream's turn the moment its stream is cut: on its next write to a request that has gone, so a
reply that was streaming ended when the app left the conversation, iOS suspended the app or the
network changed (found 2026-10-18 from a report; the first `lab.sh switch` missed it, its slow
turn wrote nothing until the end). A run (`POST /v1/runs` with the conversation's `session_id`,
one message, the model and provider every turn since a run reads neither the session's stored
model nor its lock) goes on whatever becomes of the app, and is followed through its events
(`/v1/runs/{id}/events`, `data: {"event": …}`). When those stop short the run is looked at again:
Hermes 0.22 keeps its events for whoever asks, from where they left off (`seq`, sent back as
`Last-Event-ID`); 0.21.x keeps them for the first listener only, so then its status is asked
(`GET /v1/runs/{id}`, kept an hour) until it ends, and the reply comes whole. Trouble reaching the
host is waited out for half an hour. Each run carries the message's id as its `Idempotency-Key`:
a message sent again because its answer was lost finds its run (Hermes keeps the keys for a day,
restarts or not). The run is noted as soon as it starts (`ChatActivity.noteRun`), so a
conversation opened again, after the app was closed too, takes it up as a joined turn
(`Conversation.rejoin(run:)`): on 0.22 the reply plays from its start. Whether it is still going
is what its status says (queued, running, waiting for approval, stopping), not the transcript
alone: a run waiting on an approval has its tool call in the transcript already, and the reply
goes on from that row. Two conversations each left waiting on an approval each show their own
again, answered to their own run, and neither question is sent twice. Stop stops the run
(`POST /v1/runs/{id}/stop`); leaving lets it go on. Runs also bring approvals and subagent steps to
the Hermes API on every release (the chat stream has approvals only from 0.22). What they don't
do is put the agent's pictures (`MEDIA:` tags) into the reply: the app fetches those through the
Dashboard when its login is saved, as it does for a conversation opened again. A gateway without
runs gets the chat stream. `lab.sh runs` checks all of it on each release, and `lab.sh run` that
picked models still reach the endpoint that serves them. A conversation that ends on an
unanswered question with no run noted is fetched every four seconds for ten minutes
(`Conversation.watchForLedgerReply`). Deleting the conversation, and anything on the
OpenAI-compatible connection (no host to go on), still stop the turn.

**The chat list's marks** (`Services/ChatActivity.swift`) show what became of conversations left
like that: a spinner where the time goes while the agent works, "Needs you" while it waits on an
answer, an approval or a password, and a dot in the margin for a reply not yet seen. While the
list is on screen it looks every four seconds. On the Dashboard, `session.active_list` lists the
conversations with a turn under way in that Dashboard, working or waiting (an approval counts as
waiting from 0.21.3; 0.21.0 calls it working); turns run elsewhere (cron, a messaging app, the
Hermes API) aren't in it. Unread is Hermes's own, the same for every app: `unread` in its list,
against a read mark set by `PATCH /api/sessions/{id} {"unread": …}`. A conversation nobody has
ever marked is never unread, so the app marks one read when it is opened, when it is left, when
a reply finishes on screen and when Redde comes back with it open. The Hermes API lists no turns
and doesn't return `unread`: a turn the app left mid-way is asked after by its run
(`GET /v1/runs/{id}`, `waiting_for_approval` only from 0.22, where that route first waits for
one), and what was last seen of each conversation is kept on the phone, against the time of its
last activity; the read mark still goes to the host for the other apps. The list is fetched again
when a turn ends, and at most every thirty seconds when the Dashboard says its conversations
changed (`sessions.changed`). Mark as Read / Unread is in a row's swipe and menu. Group chats
are marked too: their bots' hidden sessions are in `session.active_list` (titled `Group: <room>`,
Hermes Desktop's `Group: <room> · <thread>`), so a room's row is working while a bot answers and
Needs you while one asks the person (`ChatActivity.roomKinds`). Hermes keeps no read mark for a
room: what is new is kept on the phone, the room's latest event (its number in the log, a
Desktop room's last message time) against the one seen there.
`scripts/hermes-lab/lab.sh status` checks what each release says, and the app's own
`ChatActivity` against it (`HermesLabStatusTests`).

## Siri, Shortcuts and controls

Four App Shortcuts: "Ask Redde", "Talk with Redde" (hands-free), "Take a Note" (quick capture,
below) and "Ask a Profile" ("Ask Work in Redde"); Siri also answers to "Hermes" and "Sol". Siri only opens the app, which then listens with
its own recognizer; long free-form questions through Siri's dictation are unreliable. "Ask Redde a Question" in Shortcuts takes text and returns
the reply as text. The `EchoControls` extension provides Control Center, Lock Screen and Action Button
controls (via an App Group launch flag), Home Screen widgets (Last reply, Ask Redde, Needs you,
Context, and From Your Agent, which Phone tools' widget area writes) and the Live Activity (`Services/TurnActivity.swift`).

**Quick capture** is a note taken in passing, for Hermes to file, with nothing said back
(`Services/Capture.swift`). There are three ways in. "Take a note in Redde" (`CaptureNoteIntent`)
runs without opening the app: Siri asks for the note and answers "Noted", so it works from the
Lock Screen, AirPods and the car. The "Note to Redde" control (`StartCaptureIntent`, by the
launch flag like the others) and the "Take a Note" row under the cards on the car's Ask tab open
listening for a note with Redde's own recogniser: `VoiceSession.beginListening(capturing:)`,
after which the utterance goes to `CaptureInbox` and not to the conversation, "Noted." is said,
and the mic stays shut, hands-free or not. A stop phrase or silence takes no note. A reply being
typed out meanwhile is left running, and a note is not taken over a reply being spoken.
`CaptureInbox` keeps a note from the moment it is taken (in UserDefaults) and hands it over
as soon as it can: at once as a rule, and otherwise when the network comes back, when Redde
comes forward, and on a schedule while it runs (15 seconds, 1, 3, then every 10 minutes).
Notes that waited together go as one message. On a Hermes connection that is a turn nobody
watches, in a chat of its own called "Notes" per server and profile (`ShortcutRunner`, thread
`.notes`), which tells the agent these are notes to file where they belong and that nobody is
waiting for an answer (`CaptureFiler.message`); what it answers is in that chat and is never
read out. A note counts as handed over once the server has answered the turn at all, so one
whose turn then breaks off is not sent twice. On the OpenAI-compatible connection there is
no agent, and the notes are kept as messages in a conversation called "Notes" on the phone. A
note belongs to the server and profile in use when it was taken and waits for them. Notes not
yet handed over are listed at the top of the chat list, where a swipe throws one away, and
counted on the car's row. Tried with a stand-in for the server (`EchoTests/CaptureTests.swift`);
the turn that files a note with a real Hermes, Siri's phrase, the control and the car's row
have not been run on a device. The watch has no way in yet.

A Live Activity outlives the app, so one for a reply that never finished would sit on the Lock
Screen and in the Dynamic Island looking busy for hours when the app crashes, is closed or is
suspended mid-reply: nothing is left to end it. Every update therefore carries a stale date two
minutes off, and a heartbeat re-sends the state every 45 seconds while the reply runs, so a long
quiet tool doesn't go stale under a live app. Once updates stop, the system marks the activity
stale and its views show "Reply interrupted" with no pulse and no clock (the wording lives with
`EchoTurnAttributes`, where the app's tests can reach it). Two minutes is as soon as the system
acts; asked for less, it still waited that long. The next launch ends whatever an earlier run
left (`TurnActivity.clearStrays`).

**The task list on the Live Activity.** Through a long job the agent keeps a task list (Hermes's
to-do tool, `TodoList`), and how far it has got is on the activity: a bar, "3 of 6 done" and
the task in hand on the Lock Screen and in the expanded island, "3/6" in the island at rest.
`Conversation` hands the list over whenever the turn changes it (`TurnActivity.tasks`), and
`TodoList.progress` makes the count of it: cancelled tasks are neither done nor left, a list of
one task is not shown, and of a task and its subtask both in hand the subtask is the one named.
The count rides on the state as `ContentState.progress`, optional like the approval so that an
older state decodes, and stays on a reply that finished ("All 6 done") or stopped. A list left
from an earlier turn is not shown until this turn touches it, so a quick question about
something else doesn't wear another job's count; a command waiting for an answer takes the
activity over until it is settled. `-echo.demoTasks 3` puts a job with three of six done on
the activity (`run` moves it along). Looked at on the simulator's Lock Screen; the Dynamic
Island can't be captured there and has not been seen, and nothing has run against a real
agent's list on a phone.

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
  moment the request is answered or expires, or the turn is stopped or ends. Leaving a turn for
  another conversation keeps the entry: that turn goes on on the host and still waits.
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

## Phone tools

Things on the iPhone that the agent can ask Redde to do, because iOS lets an app do them with
its owner's permission (Settings → Phone tools; everything off until turned on): the calendar
(look up events, add one), reminders (list, add, mark done), contacts (look someone up; no
changes), the photo library (find by date, kind and what a picture shows, hand one over, delete), Redde's own
folder in the Files app (list, read, save text, delete), alarms (set an alarm or a timer,
list and cancel the ones Redde set), a widget of Redde's that the agent writes on, and calls and
messages (start a call, write a message for the person to send). Twenty-one tools,
`DeviceTool`. Nothing
reaches into another app: iOS allows no app that, and no client of any agent can do it.

**How a call travels.** The tools are declared to the agent by Redde's plugin on the Hermes
server, the one that sends notifications (`companion/hermes-plugin/redde-push/device.py`, from
plugin 1.2.0; alarms from 1.3.0): a Hermes plugin can register tools, and each of these is a handler that waits. It
writes the request down as a small file in the Hermes home and polls for an answer file, for up
to two minutes. Redde sees the tool start in the turn it is following (`Conversation.apply` →
`DeviceToolsService.toolStarted`; any tool whose name starts `phone_`), asks the plugin what is
wanted with the command the plugin already has for the app (`/redde-push device next`, by
`command.dispatch` over the Dashboard), settles whether it may be done, does it
(`DeviceToolRunner`), and hands the answer back (`device done <id> <answer>`), which the plugin
writes beside the request. Files and not memory because the two ends can be in different
processes: a turn over the Hermes API runs in the gateway's, and the app's command in the
Dashboard's. A picture or a file goes back inside the answer (up to 450 KB, what one command
has been seen to carry), is saved under the plugin's folder on the server, and the agent is
given its path. So phone tools need the Dashboard login, also when the conversation runs over
the Hermes API, and they answer only while Redde is following the turn: one started from
another client gets "the phone didn't answer" after the two minutes.

**Alarms and timers** (`DeviceAlarms`, from plugin 1.3.0) are set with AlarmKit, so they ring
like the Clock app's: through silent mode and a Focus, with Redde open or closed. `phone_alarms_set`
takes a title and either `at`, a moment (a fixed-date alarm), or `minutes`, a timer from now (a
second to a day); `phone_alarms_list` and `phone_alarms_cancel` see only what Redde set, which is
all iOS shows an app. iOS hands back an alarm's id and state and not what it was for, so the
titles are kept in a file of Redde's own (`phone-alarms.json`), and an alarm iOS no longer holds
(it rang, or was stopped on the phone) is dropped from it at the next look. Setting and
cancelling are changes: asked about each time, on the phone's screen. A timer's countdown on
the Lock Screen and in the Dynamic Island is the app's to draw (`AlarmCountdownActivity` in the
widget extension, on `AlarmAttributes<AgentAlarm>`); the alert when it rings is iOS's own.
`AlarmSetting` is the seam (`PhoneAlarmsTests`). iOS asks for the permission when the area is
turned on (`NSAlarmKitUsageDescription`). Tried on the iOS 26.3 simulator: iOS asks when the
area is turned on (`PhoneToolsUITests`), a timer and an alarm are set, listed and cancelled
through AlarmKit itself (`PhoneToolsOnDeviceTests`, which runs once Alarms has been allowed
there), and a timer set with `-echo.demoAlarm` counted down on the Lock Screen and rang with its
title. The iOS 27.0 simulator refuses the permission without asking (`mobiletimerd` logs the
request and a denial 13 ms later, on a simulator made for the purpose too), so the UI test skips
there. An iPhone on iOS 27 does ask and allow (Marta, 2026-10-13).

iOS shows and sounds an alarm as a Live Activity, the alert included. With Live Activities
turned off for Redde in the iPhone's Settings, AlarmKit still takes the alarm, counts it down
and puts it in the state "alerting", with nothing on the screen and no sound: three timers sat
ringing unheard on that phone before this was found. So nothing is set then
(`AlarmSetting.canShow`, `ActivityAuthorizationInfo().areActivitiesEnabled`): the agent is told
why and where the switch is, and the Alarms row in Settings → Phone tools says the same with a
way to the iPhone's Settings. A development build writes what iOS does with each alarm to
`alarm-trace.log` in its Application Support folder (`AlarmTrace`), which is how this was read
off the phone.

**The agent's widget** ("From Your Agent", `BoardWidget` in the widget extension; small, medium,
and two Lock Screen sizes) shows a title and a few lines the agent wrote with `phone_widget_set`
(60 and 300 characters; `phone_widget_clear` takes everything off). What it wrote is kept in the
App Group (`AgentBoard`), several at a time: `at` sets one for later and `until` gives one an
end, and what shows is the one that started last and hasn't run out, so "Leave now" until five
gives way to the day's plan again. The widget's timeline holds every such change ahead
(`BoardEntry.timeline`), which is how it moves on with Redde closed. Nothing of the person's is
read or changed, so with the area allowed the tool isn't asked about each time (its setting
reads "Allow", and no call counts as a change). The tool answers with what shows now, what
waits, and whether the widget is on a screen at all, which only the person can do.

It is the one phone tool that works with Redde closed. The plugin waits ten seconds for a phone
that is following the turn (`WIDGET_WAIT`); if none collects the call, what was written goes to
every paired phone as a sealed note of kind `widget` (`widget_by_note`, `core.widget_note`: `t`,
`b`, and `f` and `u` as the agent wrote them, read on the phone in its own time zone, which is
why `DeviceDates` is shared code). The notification extension puts it on the widget
(`AgentBoard.take`) and reloads it. iOS shows every notification that reaches the extension,
so this one says what was written, makes no sound and doesn't light the screen (`.passive`), and
each takes the last one's place (one collapse id); with Redde in front nothing is shown at all.
A phone that isn't paired hears nothing, and the agent is told so. A cron job that keeps the
widget up needs only the pairing. Tried: the store, the timeline, the tool and the note against
tests (`AgentBoardTests`, the plugin's `test_device.py`), the views drawn at each size, and the
widget on a simulator's Home Screen, filled with `-echo.demoBoard`: it showed the day's plan,
moved on to the line set for a minute later with Redde closed, and came back when that ran out.
Not tried: a note arriving on a phone (a simulated push skips the extension, and with Redde in
front the app applies it itself), nor a real agent writing on it.

**Calls and messages** (`DevicePeople`, area `people`, from plugin 1.3.0). `phone_people_call`
hands iOS a `tel:` address (or `facetime:`, `facetime-audio:`), and iOS asks "Call…?" itself
before anything dials; Redde isn't told what the person answered, and the agent is not on the
call. `phone_people_message` puts up the Messages sheet (`MessageSheet`, an
`MFMessageComposeViewController`) with the recipients and the text filled in, and answers with
whether the person sent it or closed it: no app may send a message itself. So neither is asked
about by Redde first (`DeviceTool.asksItself`, as with deleting photos, which iOS also puts to
the person), the area has no "Ask each time" (`DeviceArea.offersAsking`: it is Off or On), and
both need Redde on the screen. `to` is a number, or a name: a name is looked up in Contacts,
only with the Contacts area on, and has to come to one person and one number. Two Danas, or a
vet with a main line and an after-hours one, are answered with the choices, for the agent to
ask about or to name with `label`; a mobile is taken when there is exactly one. The agent reads
no messages and hears no call. `PeopleReaching` is the seam (`PhonePeopleTests`). Not tried
on a phone: a simulator has no phone for iOS to ask about and no Messages to open, so what iOS
shows, and what `open` answers when the person cancels, are still to be seen.

**What the agent is offered** is the phone's to say. Each area has a setting (Off, Ask each
time, Allow reading), and Redde tells the plugin which areas are on (`device areas
calendar,files`, when the switches change and each time Redde comes forward). A tool whose
area is off is not offered (its `check_fn`), and refuses if called anyway. Hermes remembers the
list of tools it worked out and that memory doesn't go by `check_fn`, so each Hermes process
that loaded the plugin watches the areas file and has the list worked out afresh when it
changes (`device._watch`, two seconds at most; found in the lab, where the gateway otherwise
never offered a tool turned on after its first turn). A conversation already open on the
Dashboard keeps the tools it started with.

**What the person is asked.** Adding, changing and deleting are put to the person every time,
whatever the area's setting; reading is too where the area says "Ask each time", with an
"Always allow reading" that moves the area to "Allow reading". The question is an alert over
whatever Redde shows, voice mode included, worded from the call's arguments (`DeviceAsk`).
Deleting photos is put to the person by iOS itself, with the photos shown, and not by Redde as
well. A question needs Redde on the screen: asked for while it isn't, the tool says so. What
needs no question still runs with the phone locked while the turn goes on. Each call is noted
in Settings → Phone tools → Asked for lately (the last forty). iOS's own permissions are asked
for when an area is turned on.

The plugin's tools live in its own toolset (`redde_phone`), on by default like any plugin's,
so with every area off the cost to a Hermes that never uses them is nothing offered and
nothing in the prompt.

**Finding a photo by what it shows.** `phone_photos_search` takes a `query` in plain words
("bowling scoreboard", "dog beach"). iOS has an index of what is in every picture, for the
Photos app's own search, and lends it to no other app; so Redde makes its own, on the phone.
`PhotoLook` looks at a picture with Vision: what is in it, from the small copy the phone always
has (about 15 ms a picture on an M-series Mac; 1,303 things it can name), and the text in it,
from a larger copy, for the kinds of picture that have some (a screenshot, a document, a sign, a
scoreboard: reading costs ten to twenty times as much as looking). `PhotoIndex` keeps what was
made out, a line a picture, in a file that is left out of backups and deleted when Photos is
turned off. Pictures are looked at newest first: a search waits up to thirty seconds for the
ones in its dates, three at a time, and the rest of the library is worked through two at a time
while Redde is open, and not while the phone is saving power or hot (`PhotoLooking`; Settings →
Phone tools says how far it has got). From iOS 27 an app can read the caption and keywords a
person wrote on a picture in Photos (`PHAsset.extendedMetadata`), and those are matched too,
for every picture, looked at or not.

`PhotoQuery` holds the words against all of that. A word on the picture counts in full; a near
relation of it, by the word embedding iOS carries, counts for less ("puppy" finds a dog, behind
"dog"); what the phone made out counts by how sure it was; text in the picture is matched as
written. Answers far behind the best are left out (asked for bowling, every ball game is a
distant relation). The agent gets the matches best first, each with what the phone made out,
the text, the caption and how well it matched, and the number of pictures not yet looked at, so
that nothing found is not taken for there being none. These are the phone's guesses: the tool
tells the agent to fetch a likely one and look. The picture itself still leaves the phone only
through `phone_photos_get`.

That tool hands over one photo a call. An agent asked for several calls it several times, one
after the other or at once, and each picture is put in the reply as it goes, where they stand
together (`PhotoGroup`). A call that started while the one before was being answered used to be
lost: its request was not with the plugin yet when the first was asked for, and nothing looked
again, so one picture came and the others waited until the server gave up. Now the phone looks
again when it is done (`DeviceToolsService.toolStarted`; found by reading, held by
`photosFetchedOneAfterAnotherAreAllShown`, not seen against a real agent).

Measured on the Mac with real pictures (macOS's own account pictures, the simulator's sample
photos, the store screenshots): "bowling" 0.98 for the bowling picture and nothing else kept,
"photo of a bird" four birds, "flowers" nine, "guitar" the guitar and then the other
instruments, "countertop" the two screenshots with that word in them. Not found: "cookie" for
a fortune cookie Vision calls a bagel. In the simulator Vision cannot be tried: it refuses on
its default device and on the CPU calls every picture a night sky, so there a picture counts
as not looked at and the tests give the index a stand-in. Not tried: any of it on a real
phone, so how long a real library takes, how much of it is on the phone at reading size with
iCloud Photos on, and what the looking costs in battery are all unknown.

**Showing a photo.** A photo the agent fetches is put into the reply as it goes
(`DeviceToolsService` hands it to the conversation before it answers the plugin): the person
sees which picture left the phone, and "show me my latest photo" shows it. For a later reply
the tool's result carries the line to write (`show_with`, a `MEDIA:` tag), and since the first
real agent to be asked "show me" answered with the file's bare path in backticks, a path into
the plugin's folder on the server is taken for the file it names, tag or no tag
(`ServeMedia.candidates`). A picture already in the reply is not fetched back or shown twice.

**Tried.** On a real phone against a real Hermes (2026-10-12, a 0.21 server with the plugin
copied in by hand): asked for the most recent photo, the agent found it, fetched it and
described it correctly. The loop also runs in the lab against unmodified Hermes 0.21.0, 0.21.3 and 0.21.5
(`scripts/hermes-lab/lab.sh device --app`): a stand-in phone over both connections, then the
app's own client, service and files tool. The calendar, reminders, contacts and photos tools
run for real in the simulator once it has been let at them
(`EchoTests/PhoneToolsOnDeviceTests.swift`), which is how "photos that are not screenshots"
was found to come back as one picture of six when asked of the library, and is now sorted out
picture by picture. Not tried: the other areas on a real phone, deleting photos (it takes a
person's tap), and the question in the car. An agent that already has a tool for the same
thing uses that one: asked for a reminder, the one tried used its own reminders tool.

## CarPlay

A CarPlay scene in the voice-based conversational category (iOS 26.4+). A tab bar with two tabs
(three on the Dashboard: see Bots below).
**Ask** is a list holding one row of three cards (`CPListImageRowItem` with card elements): **Ask**
and **Talk** carry on the conversation the phone has open, **New Chat** starts another. Above them
the row names that conversation ("Now in …"), and that line leads to the other tab; under them
are the four conversations last carried on besides that one. **Chats** is
a list of the phone's conversations to pick one from (`CarPlay/CarPlayChats.swift`: the phone's
list in its order, as names and times; a session nobody named is "Untitled chat", never the
preview of its last message), the open one marked with a check at the trailing edge. The list is
read when the car connects, when the tab is opened and when the open conversation changes. On the
Dashboard connection, with Bots on, a third tab, **Bots**, shows the server's bots (the chat list's
Bots, in the order the person put them there, else the main agent first, then the most recently
talked to) as one row of cards, five across on a 568-point screen, more on another line (asked
2026-10-22, "make the bot tab a bit more fun"). Each card is the bot's creature as big as a card
lets it be, in its colour (`CarPlayArtwork.botCard`), with its name and, in a word or two, what
it is doing ("Working", "Needs you") or when it was last talked to, never what it said. The face
is in the bot's mood (`CarPlayArtwork.BotMood`, `botPose`): working it looks up and away with a
thought bubble, needing you it stares, mouth open, with a gold "!", and after a day with no chat
(`asleepAfter`) its eyes are nearly shut beside z's. The cards come in five looks, picked in
Settings → Appearance → CarPlay bot cards (`CarPlayBotLook`, `Settings.carPlayBots`, synced; the
row shows with Bots): Sticker (a new install's: bright in the bot's colours, the face a sticker
with a white edge), Stage (a spotlight), Peek (a face too big for its card), Wide (the Ask
tab's 16 by 9, three across) and Glow; `CarPlayArtworkTests` holds each dark enough where the
car writes. With a bot's chat open, the row says whose ("Now with …"). A list can't animate, so
the cards keep up instead: while the tab is up the host is asked what the bots are doing every
five seconds, as the phone's chat list asks it (`ChatActivity.look`), and the bots are read
again every thirty (`watchBots`; under the voice card it waits); whatever a card is drawn from
is observed, and when it changes the tab is drawn again (`armBotsObservation`, only if a card
would change). Picking one opens its own chat and listens, as picking a chat does. The tab last
picked is remembered (`Settings.carPlayTab`, this phone's alone) and the car opens on it the next
time it connects, or on Ask if that tab has gone (asked 2026-10-22, "make the tab selected
sticky"; `CPTabBarTemplate.select`, which picks a tab only on a car). New Chat, a picked chat and a picked bot listen in the mode Settings → Voice
gives the phone's voice button. Each of
them ends on a voice-control card (Listening, Thinking, Speaking, Paused, Needs your phone) with
**Stop** and **Pause** in its bar while Redde listens, thinks or speaks. Neither closes the card
(asked 2026-10-20, "the pause and stop buttons both kick me out of the screen"): Stop ends
whatever Redde is doing (the reply, the agent's turn, the listening) and the card says Paused,
as the phone's Stop keeps its voice screen; Pause holds it and keeps the conversation, and the
card says Paused too. Paused, the bar has **Done** where Stop was, which ends everything,
hands-free with it, and closes the card, and **Resume** where Pause was, which listens again
after a Stop (hands-free still on if it was). The bar is set only when its buttons change, and
a card the car takes down within two seconds of one of its own buttons is put back as the voice
session stands (`templateDidDisappear`); one taken down any other way, by the car's own Back,
stays down. While Redde listens, Pause
shuts the mic (`VoiceSession.mute`, which also gives the car its audio back), so nothing said
in the car is taken for a question. While it speaks, the reply stops where it is. While it
still thinks, the agent works on and its reply waits, whole, until Resume
(`VoiceSession.pauseSpeaking`, which the phone's voice screen has while a reply is read). The
built-in voice can only be held in the middle of a sentence, so `SpeechOutput` keeps what
arrives during a hold and says it on `resume`, and a sentence Kokoro fails on meanwhile waits
too. The thinking sound is off while a reply is held. A request that waits on the phone is not
something to pause: that state has Stop alone. A voice-control template takes five states and
no more, so a finished reply closes the card and a failure is an alert. Replies are spoken only.
The buttons and the hold are tried in `EchoTests/CarPlayTests.swift` with a stand-in voice;
nobody has pressed them on a car yet.

CarPlay sizes everything in points and nothing to the screen, and two of its choices decide this
layout (both found by drawing its own views, below). A grid template's button has a 40-point
picture on every screen, so the first tab is cards, the largest buttons there are. A card made
from a thumbnail (`CPThumbnailImage`, iOS 26.4) takes the shape of its picture, which fills it,
and Redde's are 16 by 9: 146 by 82 points on a screen 770 points wide, 176 by 98 on one of 640,
which three of them fill, and 164 by 92 on one of 400, where two fill a line and New Chat goes on
a second (`allowsMultipleLines`). A square picture set inside a card, as the first version had,
makes a card 80 points wide; a 3 by 4 picture makes one of 95 by 126; any other wide picture is
squeezed into the 16 by 9 shape. On a large screen the recent conversations under the cards are
what keeps the tab from standing half empty.
And a voice state with action buttons is laid out title, picture, buttons, with the picture
given a third of whatever height is left: 10 points on a 240-point-high screen, 58 on a
480-point one. Without them it has that height less 150 points, up to its full 150. Builds 260
and 261 had Mute and End as action buttons, and on a car the card stood there with words and no
picture. So no state has action buttons, and the controls are bar buttons
(`CarPlaySceneDelegate.barButtons(for:)`). End is the leading one on purpose: a card that
offers nothing there gets a close button from CarPlay, which takes the card down without the
conversation being told. The car's own Back button still does that; nothing here hears of it.

**Short answers in the car** (Settings → Voice, off until turned on). A long reply is hard to
follow at the wheel. With the switch on, a question asked by voice while the phone is with a car
(CarPlay connected, or the car's Bluetooth as the audio route) asks the agent for two or three
spoken sentences and to offer the rest; "more" is then a question like any other and the agent
carries on (`CarBrevity`, `VoiceSession` → `Conversation.send(brief:)` → `TurnRequest.brief`).
Nothing is cut or summed up on the phone, so the reply in the conversation is the one that was
heard. Each connection asks in its own way, as for the reply language: the Hermes API in the
turn's instructions, an OpenAI-compatible server in a system message, and the Dashboard, which
takes no instructions with a message, in a line added to the message itself, which other
clients of that server show and Redde hides again (`ReplyLanguage.stripNote` takes both notes
off). That line is why it is off to begin with. A message typed on the phone is sent as it is,
and one that had to wait for a connection goes out later as an ordinary one. What the request
makes of a real agent's answers has not been heard yet, and what each connection sends was not
checked against a server (`EchoTests/CarBrevityTests.swift` holds when it is asked for).

The same switch is on the car's screen (asked 2026-10-13): a "Short Answers" row under Take a
Note on the Ask tab, which says On or Off and flips when pressed (`brevityRow`). The next
question goes by it. CarPlay's lists have no switch, only a picture at the end of a row, so one
is drawn (`CarPlayArtwork.switchMark`), and it has to stay within 44 points either way
(`CPListItem.maximumImageSize`): a larger picture is made to fit by CarPlay, which then takes
its pixels for points, and a switch 46 points wide came out 132 wide in a row twice the height.
(A symbol given as that picture is set after the row's second line instead, in grey.) The row
follows the phone's own toggle and the other way round.

**The thinking sound** (Settings → Voice: Off, In the car, Always; off until chosen). While the
agent works and nothing is being said, voice mode plays a soft double pulse round and round, so
that someone who can't look at the screen doesn't take the silence for a failure. It starts
after two and a half seconds with nothing to hear, so an answer that comes at once has none,
and stops with the reply's first sound. That covers the wait before the first word and also the
quiet in the middle of a reply while the agent is at its tools ("Let me check", then a minute
of nothing): `VoiceSession.isQuietlyWorking` is the thinking phase, or the speaking phase with
the turn's stream still open and the speech output silent, looked at five times a second
(`watchForQuiet`). It does not play while the turn waits for the person (an approval is not
work), over a reply that is held, or into a microphone left open on the phone's own speaker
(Talk over replies set to "Headphones and speaker"), where a sound that starts can pass for a
voice; on
headphones the microphone hears none of it, and in a car the microphone is shut. "In the car"
is CarPlay connected or the car as the audio route, as for short answers.

The sound is one file, `Echo/Resources/Earcons/thinking.wav`, made by
`scripts/thinking-sound.py`: one note (442.5 Hz, the octave under the listening tones' upper
note, with their overtones), two soft pulses a third of a second apart, every 3 seconds (0.22
and 2.2 until 2026-10-13, when more room between them was asked for),
peaking 6 dB under the listening tones. One pitch on purpose: the two-note tones mean the
microphone has opened or closed. `ThinkingSoundPlayer` loops it through the app's audio session
like those tones, so it goes where the reply goes, and fades it out in a tenth of a second.
Choosing it in Settings plays it twice, like a ringtone. When it starts and stops is in
`EchoTests/ThinkingSoundTests.swift`; what it sounds like, how loud it is beside a reply and
how it carries in a car are for ears, and nobody has listened yet.

The brand lives in artwork drawn in code (`CarPlay/CarPlayArtwork.swift`). The Ask tab's cards
come in six looks, picked in Settings → Appearance → CarPlay cards (`CarPlayCardLook`,
`Settings.carPlayCards`; the row is left out on an iPad, which has no CarPlay). Color, the one a
new install has, gives each card its own: blue to ask, gold to talk and green for a new chat,
with a plain white symbol. The others are Glow, Orb, Gold, Graphite and Marks, the last being the
voice bars and gold spark the cards first had. Settings shows each look as the three pictures
the car is given, and a pick made while the car shows the tab brings it up to date. The car
writes a card's two lines over the bottom left of its picture, in white by day and by night, so
every look is dark in that corner and keeps its mark to the right; `CarPlayArtworkTests` holds
the contrast for each. The voice card's pictures
move: a state's image is an animation to CarPlay (a loop of 0.3 to 5 seconds, 150 points at
most). They come in five looks, picked in Settings → Appearance → CarPlay voice screen
(`CarPlayVoiceLook`, `Settings.carPlayVoice`; asked 2026-10-13): Bars, Lamps, KITT, Orb and
Redde. Redde (asked 2026-10-19) is Redde's own bot face (`BotFace.main`, drawn by `BotAvatar` in
its colour through `BotAvatar.picture`), with no disc, in a soft light of the
state's colour: listening it looks at you, eyes drifting, and blinks once in a 4-second loop;
thinking its eyes go round, up and away (2.4 s); speaking its mouth says two syllables twice
(2.4 s, half of the pictures kept); paused its eyes are shut; waiting on the phone it looks down
at one (`CarPlayArtwork.reddePose`). Its pictures are kept by theme, so another theme draws them
again.
Bars, the one a new install has, is described first; the others follow it. They
are drawn after the dashboard of KITT, the car in Knight Rider (asked for
2026-10-11), in the mist and gold the card had before. Speaking is its voice display: three
bars of light that grow out of their middles, the centre one tallest, in a slow gold swell,
three to a loop of four seconds and not all the same height. Listening is the same bars in
mist, low and swaying: the centre one grows as the outer ones shrink and back, once in 3.6
seconds, so the picture is alive without pulsing and never looks as if it followed a voice it
cannot hear. The outer bars never stand as high as the centre one, at any moment of either loop
(asked 2026-10-13; `CarPlayArtworkTests` holds it). Thinking is one gold light gliding along a
slot and back in 2.8 seconds, a trace fading behind it. Paused stands still: two bars, the sign
on any pause button. Each bar is one piece in a faint housing, with a little light around it,
and no end of a bar moves by more than a twentieth of the picture from one picture to the next.
This is the third version. The first was stacked lamps that leapt from three dashes to the full
column within one picture with each syllable of a made-up sentence, twelve in three seconds,
and the fast movement looked odd (said 2026-10-12). A loop cannot follow the voice that is
heard, so lights that act as if they did are wrong twice over, and slow ones make no such
claim. The second kept the lamps and made them fade; solid bars were then picked to try, from
sketches of four KITT looks (2026-10-13).

Lamps is that second version, kept as a look: the same three bars as stacks of small lamps,
thirteen in the centre column and nine in each beside it, and for Thinking a scanner, a row of
eight lamps with one light running to the far end and back. It moves exactly as Bars does (the
two share `voiceBars` and `speakingLevel`, so the outer columns stay under the centre one
here too); a column grows by its edge lamp fading in (`glow(ofLamp:)`), never by a lamp at a
time. KITT is Lamps in the car's own red on a disc that is nearly black. It gives up telling
you from Redde by colour, so the height of the columns and the scanner do that. Orb is the
other family: a ring of light around Redde's own marks, close to the phone's voice orb. A
glint goes round the ring in 4.8 seconds while you are heard, around five voice bars in mist;
while Redde thinks a gold comet circles the spark in 1.8 seconds, its tail a third of the ring
long; while it speaks, rings spread from the spark to the ring, a new one every 1.2 seconds,
each leaving the spark unlit and unlit again when it arrives (`ringLight`, `ripples`). Those
are the speeds of the sketch that was picked from. Paused and "needs your phone" stand still
in every look, drawn in its manner.

The pictures are drawn ahead of time at the car's display scale, thirty-six to sixty to a
loop. The bars' loops come down the way they went up, so each picture serves twice and is one
object, not two copies, and the orb's speaking loop is its first half twice; that leaves about
a hundred different ones in any look (112 at most), some 40 MB while the car is connected.
Only the picked look's are kept: picking another lets the old ones go and draws the new ones
at once, for the next card to open (a card that is up keeps its pictures, since a template's
states cannot be changed). Settings shows each look as its Listening, Thinking and Speaking
pictures and plays the picked one's loops there (`voicePicture`, drawn small and not kept),
so a look can be judged without a car. Reduce Motion gets the still pictures, on the car and
in Settings. On iOS 27 each state
also has a backdrop behind the whole card (`voiceBackdrop`): graphite with a soft light, gold
while Redde thinks and speaks and mist otherwise, as one image holding a dark and a
light picture, because the card writes its words in the car's own appearance.

`scripts/carplay-preview.sh` draws all of this without a car: `EchoTests/CarPlayPreviewTests.swift`
hands the app's real templates to the view controllers CarPlay itself uses (in the simulator's
CarPlaySupport framework, by class name, so it can break with any iOS release) and writes PNG
files at car-screen sizes in both appearances, with the measured sizes beside them. It leaves out
the car's status bar and the tab bar. Look at its pictures before changing anything here: two
rounds of this work were done from the headers alone and both looked wrong on a car. What size a
given car's screen is in points can't be read off its dashboard, so a development build writes it
down when the car connects (`noteScreen`, a file in Application Support).

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

**Bots on the watch.** A bot lives on the Dashboard, so the watch always asks one through the
phone, whichever road its own questions take. The phone hands over the bots it can reach with the
connection (`WatchConnection.bots`: name, profile and a 40-point picture of the creature, drawn on
the phone; the main agent and hidden bots left out, eight at most), only with the Dashboard
signed in and Bots on, and again whenever the roster changes (`WatchLink.botsChanged`). The
watch's Chats screen has a Bots section; picking one points the watch at it (its name at the
top), and its questions go to the phone with the bot's profile (`WatchRelay.Request.bot`). The
phone asks in the bot's own chat (`Backend.botChat`), which it never renames nor keeps as the
watch's session. New Chat or a picked conversation goes back to the agent. The hint a watch's
question carries ("…read aloud…") is taken off where a transcript shows it
(`WatchConnection.withoutHint`).

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
  dark faces and the user's own accent and bubble colours. 14 app icons (Redde Face the default) and 13 voice orbs, three lights inside the picture ones.
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

### Sync with iCloud

Settings → iCloud → Sync with iCloud (`Services/CloudSync.swift`): the person's settings and Hermes
servers on every device signed in to the same Apple Account. Off until turned on, on each device.

- **Where:** the settings in `Settings.syncedKeys` and each server's record go in iCloud's
  key-value store (`NSUbiquitousKeyValueStore`; entitlement `ubiquity-kvstore-identifier`), one key
  apiece (`setting.<key>`, `server.<id>`), so two devices changing different things never undo
  each other. A server's keys and passwords (`Keychain.syncable`: API keys and per-profile keys,
  Dashboard password, Cloudflare Access secret, custom headers, and the OpenAI-compatible key) go in
  iCloud Keychain: synchronizable, `WhenUnlocked`, each account in one place or the other. Never a
  browser sign-in (each device refreshes its own tokens), the push secret or the SSH key.
- **Each device's own:** the connection in use and the server it is on; on each server, the profile
  and model it is on (kept from the device's record when another's arrives); what Redde does on
  opening, App Lock, Siri, Phone tools, permissions (notifications, motion) and the push relay.
- **Following:** every setting is saved through `Settings.store`, which calls `onStore`; CloudSync
  sends the synced ones whose value differs from iCloud's. Another device's values arrive as
  `didChangeExternallyNotification` and are taken through `Settings.applySynced` and
  `mergeSyncedServers`, with `applying` set so nothing is sent back. At launch, iCloud's values are
  taken (its local copy is never behind this device's, as every change here goes there at once).
- **Servers removed:** a server removed on one device leaves a tombstone (`servers.removed`) and its
  iCloud Keychain secrets are deleted; the others drop it, unless they are on it. A device keeps the
  ids it has seen in iCloud, so one missing from its list was removed there.
- **Turning on:** where iCloud has nothing (no `redde.sync` marker), the device waits a few seconds
  for a first answer from iCloud (a new device's store fills moments after launch), then sends
  the settings it has set and its servers. Where another device's are there, it takes them, adds its
  servers, and moves from a blank server (a new install that skipped setup) to theirs.
  Local secrets move to iCloud Keychain, unless another device put one there for the same account.
- **Turning off,** and Erase everything (which turns it off first): a copy of each secret comes back
  to the device; what is in iCloud stays for the other devices.
- **Keychain cache:** iCloud Keychain says nothing when another device changes a secret, so the
  cache is dropped on coming to the foreground and when servers arrive.

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
