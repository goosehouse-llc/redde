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
scripts/hermes-lab/lab.sh push           # the push plugin: pairing, and notes for replies and approvals
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
message through the app's own client and answers the card, once with yes and once with no.

The Dashboard changed how it asks. Hermes 0.21.0 sends an `approval.request` notification,
answered by an `approval.respond` call. Hermes 0.21.3 sends a JSON-RPC request to the client,
answered by the response frame with the same id, and 0.21.5 sends it only to a client that has
said `client.capabilities {server_requests: true}`; for any other, the command is refused at once. The
same goes for the agent's questions, the sudo password and secrets (`HermesServeClient.prompt`).

## Push

`push` runs the `push` scenario: the plugin from `companion/hermes-plugin/redde-push` copied into
the lab's Hermes home, the relay's own code under Node (`companion/push-relay/test/local.mjs`), and
`fake_apns.py` in place of Apple, which writes down every notification it is handed.
`push_check.py` plays the phone: it registers with the relay, answers the link that
`hermes redde-push pair` prints, and opens what arrives. A reply over the Hermes API has to reach
it; over the Dashboard, only once the conversation is followed, and then an approval too; and
nothing "Apple" was handed may contain a word of it.

`--app` then does the pairing with the real app (`EchoUITests/PushPairingUITests`): the app opens
the link, pairs, and has to show the next reply's text in a notification. The simulator is the one
named by `REDDE_LAB_SIMULATOR` (a name or an id). It gets notifications as simulated pushes, which
skip the app's notification extension; the app opens them itself while it is in front. The
extension opening one with the app closed takes a real push and a phone. Needs Node 20 or later.

Not covered: cloud providers (no keys here), and a conversation with no model picked on Hermes
0.21.3 or older over the Hermes API, which fails from the second turn on the server's side.

When Hermes ships a release, add its tag to `DEFAULT_TAGS` in `lab.sh`.
