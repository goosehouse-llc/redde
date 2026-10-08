# Hermes lab

A regression check against Hermes as it ships. Two of its questions are ones a personal Hermes hid
(local patches, an older release): when someone picks a model in Redde, does the turn reach the
endpoint that serves it? When the agent wants to run a command it has to ask about, is the app
asked? The third is whether the push plugin works inside each release.

```
scripts/hermes-lab/lab.sh run            # Hermes 0.21.0, 0.21.3 and 0.21.5, five provider setups
scripts/hermes-lab/lab.sh run --app      # also runs EchoTests/HermesLabTests against each lab
scripts/hermes-lab/lab.sh run v2026.9.24 # one release; any tag of NousResearch/hermes-agent
scripts/hermes-lab/lab.sh approvals      # the app's Dashboard client is asked before a command runs
scripts/hermes-lab/lab.sh signin         # the app's Dashboard client signs in through a browser
scripts/hermes-lab/lab.sh admin          # Settings → Gateway: status, MCP servers, logs, a restart
scripts/hermes-lab/lab.sh controls       # one conversation's switches (run without asking, fast mode), and a move to a project
scripts/hermes-lab/lab.sh todos          # the agent's task list as a reply's checklist, on both connections, live and reopened
scripts/hermes-lab/lab.sh push           # the push plugin: pairing, and a note for everything it announces
scripts/hermes-lab/lab.sh push --app     # and the app in a simulator pairs with each release
scripts/hermes-lab/lab.sh up v2026.9.24 two   # leave one lab running to poke at; `down` stops it
```

Each release is cloned and installed once under `~/.cache/redde-hermes-lab` and run on loopback
with its own `HERMES_HOME`; your `~/.hermes` is never read or written. Two stub endpoints stand in
for model servers: `stub_llm.py` answers every completion with `[<stub>:<model>]` and logs it, so a
check knows where a turn went. Stub A serves `alpha` and `beta`, stub B serves `gamma`.

| Scenario | Hermes config |
|---|---|
| `named` | one `custom_providers` entry |
| `two` | two `custom_providers` entries on different URLs |
| `bare` | `model.provider: custom` with `model.base_url` |
| `keyed` | a keyed `providers:` entry |
| `leftover` | a named entry plus a `providers: custom:` block with no URL, which Hermes lists as a model row that cannot route |

`check.py` sends what the app sends for each listed model, as a new conversation and as a switch
in an open one, on both connections:

- **Dashboard** (`hermes serve`): `session.create` with model and provider; `config.set key=model`
  with `"<model> --provider <slug>"`.
- **Hermes API**: `POST /api/sessions`, chat turns carrying `model`, `provider` and
  `require_model_lock`, and `POST /api/sessions/{id}/model`.

It mirrors `Conversation.liveProvider`, `HermesServeClient.modelSwitchValue` and
`HermesSessionsTransport`; change those and this together. `--app` runs the real Hermes API
transport (`EchoTests/HermesLabTests`) in the simulator, which shares the Mac's loopback; that test
skips when no lab is up, so the normal suite is unaffected.

## Approvals

`approvals` runs the `approval` scenario on each release: approvals set to ask a person, and a
Dashboard with a public address, so it asks for a login (`lab` / `labpass-labpass`) and the app
signs in as it does on a real server. A message containing "danger" makes the stub call the
terminal tool with `rm -rf` on a folder it has just made, and it answers the tool's result with
`[gone]` or `[kept]` by looking for the folder. `EchoTests/HermesLabApprovalTests` sends that
message through the app's own client and answers the card, once with yes and once with no. Then it
does what a closed app has to: a client starts the turn and disconnects, a second one joins the
turn where it waits and answers its card, and a third answers without a card, by session and by
the command's digest, as Approve and Deny on a notification do. The same joining is done for a
turn left waiting on a question, on the sudo password and on a secret (the stub's `lab:question`,
`lab:sudo` and `lab:secret`, below); Hermes 0.21.0 doesn't list those for a returning client,
which the test says and doesn't count against it. A question is also answered the way a reply
on its notification is, by session and by the question's digest, and the stub says back what
it was told (`[answered: release]`). And a message is sent with a file attached,
a text file and then a video: the Dashboard only stores such a file, and the agent hears of it
when the message names it. The stub answers a message with `lab:file` in it `[file seen]` when
the file's text, or the name of one that can't be read as text, reached the model.

The Dashboard changed how it asks. Hermes 0.21.0 sends an `approval.request` notification,
answered by an `approval.respond` call. Hermes 0.21.3 sends a JSON-RPC request to the client,
answered by the response frame with the same id, and 0.21.5 sends it only to a client that has
said `client.capabilities {server_requests: true}`; for any other, the command is refused at once. The
same goes for the agent's questions, the sudo password and secrets (`HermesServeClient.prompt`).

## Sign-in

`signin` runs the `approval` scenario again, for its Dashboard login, and signs the app's client in
the way a Dashboard with Google or another identity provider needs: through a browser, by the
Dashboard's native sign-in routes (`/auth/native/authorize`, `/token`, `/refresh`), with no
password in the app. `EchoTests/HermesLabSignInTests` stands in for the person: it opens the
address the app would hand the browser, logs in on the Dashboard's page, and follows the way back
to the app's loopback listener. Then the app's tokens have to work for a REST call and for the
WebSocket's ticket, a token the Dashboard refuses has to be refreshed and the call retried, and a
refresh token it no longer takes has to end in "sign in again". The lab's login is a password, so
what a real identity provider adds (its own pages, in the browser) is not covered.

## A conversation's switches

`controls` runs `EchoTests/HermesLabChatControlsTests` on the `approval` scenario. The app's
client turns "run commands without asking" on for one conversation and sends the stub's "danger"
message: `rm -rf` has to run unasked (`[gone]`). Off again, it has to be asked about (`[kept]`),
and a second conversation has to be asked throughout. Fast mode is switched on and has to be
refused, since the stub's model has none; a real one would take an OpenAI, Anthropic or xAI
model. Then the conversation is moved to a folder made for the test, has to show up under that
project, and a folder that doesn't exist has to be refused.

## The agent's task list

`todos` runs `EchoTests/HermesLabTodoTests` on the `approval` scenario. The stub model writes a
three-item list (`lab:todo`), ticks it by a merge in the next turn (`lab:tick`), then sends a
merge whose item has no words (`lab:badtick`), which 0.21.3 and later turn down without running
the tool. Where the to-do tool isn't offered to the model outright, the stub reaches it through
`tool_call`, as a real model does there. The checks: over the Dashboard, a conversation of the
app's own shows the list after each turn, and has it back, with its steps, when the session is
read again; over the Hermes API, the list is read from the calls as they stream, then from the
tool's own answer when the turn is over, and both replies have the same list when read back.

Two things print as notes (`----`) and not as failures, because they are how that Hermes is:
0.21.3 and later turn the wordless merge down, and their API starts each turn on an empty list,
so the merge there leaves two items where the Dashboard has three.

## Gateway administration

`admin` runs the `admin` scenario: the `approval` one plus an MCP server, switched off, that is the
lab's own stand-in (`mcp_stub.py`: the handshake and one tool). `EchoTests/HermesLabAdminTests`
drives the Gateway screen's model with the app's own client: the status and the host, the server
switched on, tested and switched off, the logs with a level and a search, the update check, and a
restart followed to its end.

The lab's gateway is started by hand, with no service manager, and the releases differ there.
0.21.0 and 0.21.3 stop it and run the new one inside the restart command, which never ends; the
app takes a newly started, running gateway for the end. 0.21.5 stops it and starts nothing, which
the test prints as a note and checks that the app says so. A restart through a service manager is
not covered here.

Two things the lab never does: Hermes's `start` (on 0.21.5 it installs a launchd service on this
machine when there is none) and an update (it would fetch and install into the lab's checkout).

## Push

`push` runs the `push` scenario: the plugin from `companion/hermes-plugin/redde-push` copied into
the lab's Hermes home, the relay's own code under Node (`companion/push-relay/test/local.mjs`), and
`fake_apns.py` in place of Apple, which writes down every notification it is handed.
`push_check.py` plays the phone: it registers with the relay, answers the link that
`hermes redde-push pair` prints, and opens what arrives. A reply over the Hermes API has to reach
it; over the Dashboard, only once the conversation is followed, and then an approval too; and
nothing "Apple" was handed may contain a word of it. A second stand-in phone pairs with no code,
over the Dashboard, the way an app signed in to it does. The Dashboard has a login here, as in
the approval scenario.

The stub model does more on request, so the plugin's other notes can be checked. A message with
one of these words in it, while it is the last thing said:

| | the model | the note |
|---|---|---|
| `lab:question` | calls `clarify` with a question and two choices | `question` |
| `lab:sudo` | runs `sudo true` (skipped where sudo wants no password) | `sudo`, on 0.21.3 and later |
| `lab:secret` | opens the skill `lab-secret`, which the lab makes and which wants `LAB_SECRET_TOKEN` | `secret`, on 0.21.3 and later |
| `lab:delegate` | hands a subagent a small task | `task`, when it comes back |
| `lab:refused` | is refused with a 401 | `failed`, 20 seconds on |
| `lab:hiccup` | fails twice with a 500, then answers | `reply`, and never `failed` |
| `lab:outage` | fails with a 500 every time | `failed`, 150 seconds after Hermes's last try; only with `LAB_PUSH_SLOW=1`, since 0.21.5 keeps trying for five minutes |

Nothing answers the question, the password or the secret: the check reads the note, asks the
Dashboard what the session waits on (what a client that opens the conversation is told), and
stops the turn. The check also runs Hermes's install scan over the plugin, which refuses, among
other things, any mention of sudo in a plugin's code or README.

`--app` then does both pairings with the app's own code. `EchoTests/HermesLabPushTests` signs the
app's Dashboard client in and pairs through the app's push service in one step. And
`EchoUITests/PushPairingUITests` drives the app itself: it opens the link, pairs, and has to show
the next reply's text in a notification. The simulator is the one
named by `REDDE_LAB_SIMULATOR` (a name or an id). It gets notifications as simulated pushes, which
skip the app's notification extension; the app opens them itself while it is in front. The
extension opening one with the app closed takes a real push and a phone. Needs Node 20 or later.

Not covered: cloud providers (no keys here), and a conversation with no model picked on Hermes
0.21.3 or older over the Hermes API, which fails from the second turn on the server's side.

When Hermes ships a release, add its tag to `DEFAULT_TAGS` in `lab.sh`.
