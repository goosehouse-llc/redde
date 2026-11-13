# Redde bridge

Redde's way to agents that speak ACP, the [Agent Client Protocol](https://agentclientprotocol.com):
Claude Code, Codex, Gemini CLI, Goose, Hermes and others. ACP runs over stdio, so an editor
starts the agent as its own child process. A phone can't do that. This bridge runs on the computer
with the agents, starts each one the first time it is wanted, and serves it to Redde over a
WebSocket. It also adds what a phone needs and ACP leaves out:

- **A turn outlives the phone.** Lock the phone mid-reply and the agent carries on. When Redde
  comes back, it catches up from where it left off (`_redde/attach`).
- **Several devices.** An iPhone, an iPad and a Mac can have one chat open at once, and each one
  sees the reply as it is written.
- **Approvals from any device.** A question the agent asks shows on every device on that chat. The
  first answer is the one taken, and the others clear.
- **Restarts are quiet.** After the bridge or the agent restarts, a chat is reloaded before its
  next message, so it carries on where it was.
- **A working folder.** ACP needs a folder for every chat. When Redde names none, the agent's
  `cwd` from the config is used.
- **Notifications when Redde is closed.** A reply is ready, an agent waits for your approval, a
  turn failed. In Redde: Settings › Notifications › Alerts When Redde Is Closed › Pair with
  <this connection>. See below.

The design and the wire format are in [docs/acp.md](../../docs/acp.md).

## Install

On the computer with your agents (a Mac, or Linux with systemd), in a terminal:

```
curl -fsSL https://raw.githubusercontent.com/goosehouse-llc/redde/main/companion/redde-bridge/install.sh | sh
```

It puts the bridge in `~/.local/share/redde-bridge`, writes a config with a new token and the
agents it finds, and runs the bridge as a service that starts with the computer and comes back if
it stops (a LaunchAgent on a Mac, a systemd user service on Linux). Then it shows a QR code: scan
it with the iPhone's Camera or Redde's Scan a setup code, and Redde shows what it sets up and saves
it when you agree. The code holds the token, so show it only to your own devices.

When Tailscale is running on the computer, the setup uses its Tailscale name, which reaches it
at home and away; otherwise its `.local` name, which works on the same Wi-Fi only. To give another
name: `… | sh -s -- --host <name>`. Run the installer again to update; the config and token stay.
From 0.7 an installed bridge can also update itself: Redde shows Update Bridge in the server's
settings when a newer one is out. It downloads the files from the same place as the installer,
checks they start on this Python, keeps the old ones in `~/.local/share/redde-bridge/previous`
and restarts. It waits while a reply is under way.

It needs Python 3.9 or later and nothing else (a Mac has it once the Command Line Tools are
installed: `xcode-select --install`). Logs are in `~/Library/Logs/redde-bridge.log` on a Mac and
`journalctl --user -u redde-bridge` on Linux. To remove it:
`python3 ~/.local/share/redde-bridge/redde_bridge.py --uninstall`.

## Run it by hand

```
python3 redde_bridge.py --print-setup   # writes a config the first time; shows what to type into Redde
python3 redde_bridge.py                 # serve
python3 redde_bridge.py -v              # serve, logging every agent's own output too
python3 redde_bridge.py --install       # what the installer runs: this copy, as a service
```

`--print-setup` prints a setup link for each agent and a QR code of the first (`--agent <id>`
picks another), and `--host <name>` names the computer the way the phone reaches it, for example
its Tailscale name (`tailscale status --json` says it as `Self.DNSName`).

The first run writes `~/.config/redde-bridge/config.toml` (`REDDE_BRIDGE_CONFIG` or `--config`
moves it). It has a new random token and an entry for each agent it found on this computer.
Agents it didn't find are in the file too, commented out:

```toml
listen = "0.0.0.0:8765"
host = "studio.example.ts.net"   # optional: the name in setup links (the installer sets it)
token = "…"
# tls_cert = "/path/to/cert.pem"
# tls_key = "/path/to/key.pem"

[agents.hermes]
name = "Hermes"
command = ["hermes", "acp"]
cwd = "~"

[agents.claude]
name = "Claude Code"
command = ["npx", "-y", "@agentclientprotocol/claude-agent-acp"]
cwd = "~/Projects"
env = { SOME_SETTING = "value" }   # optional, added to the agent's environment

[agents.codex]
name = "Codex"
command = ["npx", "-y", "@agentclientprotocol/codex-acp"]   # sign in first with `codex login`
cwd = "~/Projects"
```

Any program that speaks ACP over stdio can be an agent. The agent signs in the way it normally
does on this computer, for example Claude Code with its own login. The bridge never sees or
passes on a model key.

In Redde, by hand: **Settings › Connection › Set up connection… › Claude Code, Codex and others (ACP)**. Enter the address,
the token and (when the bridge has more than one agent) pick an agent. A folder is optional.

## Keep it private

The token is the only lock. Anyone who has it can do whatever the agent can do on this computer.

- Plain `ws://` sends the token without encryption. Use it only on a network you trust, or over
  Tailscale or a VPN. Better still, set `listen` to that network's address only, for example
  `100.x.y.z:8765` for Tailscale.
- For anything else, set `tls_cert` and `tls_key`, and Redde connects with `wss://`. A Tailscale
  certificate (`tailscale cert`) works well for this.
- To change the token, edit `token` in the config and restart. Every device then needs the new one.

## Notifications

Pairing is one tap in Redde, over the bridge's own connection: the two agree on a key (X25519,
HKDF-SHA256), and every note is sealed with AES-256-GCM before it leaves this computer. It goes
through Redde's relay (`https://redde-push.goosehouse.org`, or `push_relay = "…"` in the config)
and Apple, and neither can read it. The scheme is the one Redde's Hermes plugin uses
([docs/push.md](../../docs/push.md)); `redde_push.py` has it in plain Python, checked against the
published test vectors (`tests/test_push.py`).

The paired devices are kept in `push.json` beside the config, readable only by you. Remove a
pairing in Redde and the bridge forgets that device with its next note. A pairing belongs to the
agent it was made through: with Claude Code and Codex on one bridge, pair each of Redde's
connections, and each hears about its own agent's chats (pairings from bridge 0.4 and earlier hear
about every agent). A device with Redde open shows nothing extra.

The computer needs to reach the relay over HTTPS. Keep `redde_push.py` beside `redde_bridge.py`.

## Endpoints

| | |
|---|---|
| `GET /acp/<agent>` (WebSocket) | ACP for one agent: one JSON-RPC message per text frame |
| `GET /agents` | the agents, as JSON: id, name, whether it is running, its folder; and the bridge's `version`, `service` and `updatable` |
| `GET /health` | `ok`, with no token needed |

The token can come in any of three ways: `Authorization: Bearer <token>`,
`X-Secret-Key: <token>`, or `?token=<token>`.

Beyond plain ACP, it adds these extensions:

| | |
|---|---|
| `_redde/attach {sessionId}` | follow a session. Returns `running`, the turn's `prompt`, `seq`, `stopReason`, its `updates` and the questions waiting on an answer |
| `_redde/detach {sessionId}` | stop following one |
| `_redde/turn_ended` | notification: a turn ended, with its `stopReason` |
| `_redde/request_resolved` | notification: a question was answered on another device, or withdrawn |
| `_redde/push {command}` | pairing for notifications: `offer`, `accept <offered> <public key> <box>`, `test`, `list`; answered `{output}` in the words of Redde's Hermes plugin |
| `_meta.redde.seq` | added to every `session/update`, so a device that catches up can skip what it already has |
| `_redde/update` | the installed bridge updates itself from where the installer gets it (`REDDE_BRIDGE_BASE`), then restarts: `{updated, from, version}`, or `{updated: false}` when it's the newest. Refused while a reply is under way, and by a bridge run by hand (its error's `data.command` is the install line) |
| `session/list`, `session/set_title` | for an agent that keeps no list of its chats (Gemini CLI), the bridge keeps one: the chats started through it, named by their first message or by Rename, newest first, saved as `chats-<agent>.json` beside the config. `initialize` then says the agent can list and name them |
| `_meta.redde.service`, `.updatable` | on `initialize`: `launchd` or `systemd` when the bridge was installed with `--install`, so it can update itself |
| `_meta.redde.commands` | on `initialize`: the agent's slash commands as its last session said them, for a new chat that has heard none yet |

Everything else goes to the agent as it is (`session/set_title`, `_session/steering`, `session/set_config_option`…). A `session/fork` is followed as the new session it makes, already open in the agent.

## Test it

```
python3 -m unittest discover -s tests -v   # the bridge in front of a scripted agent (tests/fake_agent.py)
../../scripts/acp-lab.sh up                # the bridge in front of a real `hermes acp`, on a stub model
```
