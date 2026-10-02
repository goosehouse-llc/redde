# Hermes lab

A regression check for one thing: when someone picks a model in Redde, does the turn reach the
endpoint that serves it, on Hermes as it ships? It exists because a personal Hermes with local
patches hid two bugs that every other server had.

```
scripts/hermes-lab/lab.sh run            # Hermes 0.21.0, 0.21.3 and 0.21.5, five provider setups
scripts/hermes-lab/lab.sh run --app      # also runs EchoTests/HermesLabTests against each lab
scripts/hermes-lab/lab.sh run v2026.9.24 # one release; any tag of NousResearch/hermes-agent
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

Not covered: cloud providers (no keys here), and a conversation with no model picked on Hermes
0.21.3 or older over the Hermes API, which fails from the second turn on the server's side.

When Hermes ships a release, add its tag to `DEFAULT_TAGS` in `lab.sh`.
