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
which the test says and doesn't count against it.

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
