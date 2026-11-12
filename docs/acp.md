# Redde and other agents: the ACP connection

Status: spec and first build, 2026-11-11. ACP is the Agent Client Protocol (Zed and JetBrains,
agentclientprotocol.com), stable version 1 (schema v1.31.0). The research behind the choice is
in `tmp/reports/Redde on other agent platforms.md` (not in git).

## What it is for

One connection that reaches any agent that speaks ACP: Claude Code (through `claude-agent-acp`),
Codex (`codex-acp`), Gemini CLI (`gemini --acp`), Goose (`goose acp`, or `goose serve` directly),
OpenCode, Copilot CLI, Cursor, Kimi, Qwen Code, and the Hermes Agent itself (`hermes acp`). It sits
beside the two Hermes connections. It does not replace them: for Hermes the Dashboard and the
Hermes API stay the full experience (bots, cards, phone tools, push, briefings).

## The pieces

```
iPhone / iPad / Mac          the host machine
┌────────────┐   WebSocket   ┌──────────────┐  stdio  ┌──────────────────┐
│ Redde      │ ───────────── │ redde-bridge │ ─────── │ hermes acp       │
│ AcpClient  │  bearer token │ (Python, no  │ ─────── │ claude-agent-acp │
│ AcpTransport│  JSON-RPC    │  packages)   │ ─────── │ codex-acp …      │
└────────────┘               └──────────────┘         └──────────────────┘
```

ACP itself only runs over stdio: an editor starts the agent as a child process. A phone can't do
that, and the draft remote transport (RFD "Streamable HTTP & WebSocket", Active since 2026-07-02)
leaves out what a phone needs: missed output is not replayed after a disconnect, there is one
client per session, there is no push, and auth is left to each server. The bridge supplies those.

The phone speaks the RFD's WebSocket profile: one JSON-RPC message per text frame, at `/acp`.
So the same client also connects to a server that speaks remote ACP itself (`goose serve`), with
no bridge, minus the extras below.

## The bridge (`companion/redde-bridge`)

One Python file, standard library only (Python 3.11 or later), so it runs wherever the agents run:

```
python3 redde_bridge.py            # first run writes ~/.config/redde-bridge/config.toml and a token
python3 redde_bridge.py --print-setup   # the address and token to type into Redde
```

Config (`config.toml`):

```toml
listen = "0.0.0.0:8765"
token = "…"                  # made on first run; Redde sends it as `Authorization: Bearer …`
# tls_cert = "…"; tls_key = "…"   # or put it behind Tailscale / a reverse proxy

[agents.hermes]
name = "Hermes"
command = ["hermes", "acp"]
cwd = "~"                    # the folder a new chat works in when the phone names none

[agents.claude]
name = "Claude Code"
command = ["npx", "-y", "@agentclientprotocol/claude-agent-acp"]
cwd = "~/Projects"
```

### What it does

- **Routes.** `GET /agents` (bearer) lists the agents: id, name, whether running. `GET /acp/<id>`
  upgrades to the WebSocket for one agent; `/acp` alone means the first.
- **One process per agent, shared.** It starts the agent on first use and keeps it. It does
  `initialize` with the agent once and answers each phone's `initialize` from that, so a second
  device doesn't restart anything. Request ids are rewritten so several phones share one stdio.
  If the agent exits, the next request starts it again.
- **Follows sessions.** A connection that creates, loads, resumes, prompts or attaches to a session
  hears that session's `session/update`s. Updates go to every connection following it (iPhone,
  iPad and Mac at once).
- **Keeps a turn going when the phone goes.** The bridge, not the phone, is the agent's client: a
  prompt runs to its end whether or not anyone is still connected. It sends
  `_redde/turn_ended {sessionId, stopReason}` to every follower when the agent answers the prompt.
- **Catch-up.** It keeps each session's updates since its last prompt began, numbered
  (`_meta.redde.seq` on every update it forwards). `_redde/attach {sessionId}` returns
  `{running, prompt, updates, permissions}`: whether a turn is under way, what was asked, what it
  said so far, and what it is waiting on. Redde's `rejoin` and its reconnect both use it.
- **Approvals, first answer wins.** A `session/request_permission` from the agent goes to every
  follower under a stable id (`perm-<n>`), so an answer from any device, even after a reconnect,
  is taken. The first answer goes to the agent; the others get `_redde/permission_resolved`.
  With no one connected the request waits (Hermes denies after 300 s on its own).
- **Loads the session it is about to use.** After a restart the agent knows a session but hasn't
  loaded it. Before a prompt to such a session the bridge resumes it (`session/resume`) or loads
  it quietly (`session/load`, replay dropped).
- **History while a turn runs.** A `session/load` replays the transcript to the asking connection
  only. While a turn is under way in that session the bridge doesn't pass the load on (the replay
  and the live turn would mix); it answers with error -32002 and Redde shows its own copy plus the
  turn from `_redde/attach`.
- **Fills `cwd`.** ACP needs an absolute folder on the host for every session. When the phone
  sends none (or `~`-relative), the bridge uses the agent's `cwd` from config, expanded.
- **Keepalive.** WebSocket pings every 20 s; a connection that misses two is dropped.

### Not yet (phase 2)

- Push for approvals and finished turns, through Redde's existing relay (pairing as the Hermes
  plugin does, ciphertext only).
- A setup code / QR for the bridge (as `redde-push` pair prints one).
- TLS made easy (today: give it a cert, or use Tailscale Serve / a proxy).

## The app

### Settings

A fourth connection on the setup screen (Settings › Connection › Set up connection…, and a new
server's setup): **Other agent (ACP)**, in `AcpServerFields`. Fields:

- Bridge address (`ws://`, `wss://`, `http(s)://` taken as the same), token (Keychain).
- Agent: picked from the bridge's `/agents`, or typed (for `goose serve`, which has one).
- Workspace folder (optional): the folder new chats work in; empty = the bridge's default.

Saved on the server record (`HermesServer.transport = .acp`, `acpURL`, `acpAgent`, `acpFolder`),
the token in the Keychain under the server's id, synced with iCloud like the other secrets.

### Mapping into Redde

| ACP | Redde |
|---|---|
| `agent_message_chunk` (text) | `.textDelta` |
| `agent_thought_chunk` | `.reasoningDelta` |
| `tool_call` | `.toolStarted(name: title, args: rawInput)` |
| `tool_call_update` completed / failed | `.toolFinished(output: content text)` |
| `plan` | `.todos` (entries numbered as ids) |
| `usage_update` | `.usage(contextUsed: used, contextMax: size)` |
| `session_info_update` title | the chat's title |
| `session/request_permission` | `.interrupt(.approval)`; options mapped to once / session / always / deny |
| `available_commands_update` | slash commands in the composer (phase 2) |
| `notice` | a status line |
| prompt answer / `_redde/turn_ended` | `.done`; `refusal`, `max_tokens` as a note |
| `session/list` | the chat list (title, `updatedAt`, `cwd` as the project) |
| `session/load` replay | the transcript: user chunks, agent chunks, tool calls, thoughts, plan |
| `session/delete` (when offered) | Delete |
| config option, category `model` | the model picker; `session/set_config_option` before the prompt |
| config options, categories `mode` and `thought_level` | menus in the model sheet, one per option with two or more values (Claude Code: Mode = Manual / Accept Edits / Plan / Auto / Bypass, and Effort). A pick goes to the open chat with `session/set_config_option` and is remembered per address for new chats, set right after `session/new` |
| `session/cancel` | Stop |
| `_redde/attach` | `rejoin`: a turn under way, joined part-way |

The client advertises no `fs` or `terminal` capability: the agent uses its own tools on the host.
Prompts are text, plus images where the agent offers `promptCapabilities.image`; text files go
inline, and other attachments are refused before sending. The person's instructions, reply
language and units go to the agent once, as the session's system prompt, where the agent offers
`sessionCapabilities.systemPrompt`. Nothing is added to the messages themselves: they are the
agent's history and are shown again whenever the chat is opened.

### What ACP chats don't have

Hermes-only features are hidden on an ACP connection rather than shown broken: bots and group
chats, briefings and the Today drawer, the Redde plugin (cards, phone tools, push), workstreams,
Dashboard admin, profiles, rename/pin/archive/unread (ACP v1 has none; a draft RFD adds titles and
archive), clarifying questions (ACP's `elicitation` comes in phase 2). Voice, CarPlay, the Watch
(through the phone), the transcript, search inside a chat, quoting and suggested replies all work.

## Testing

- `companion/redde-bridge/tests/test_bridge.py`: the bridge against a scripted fake agent (several
  clients, a disconnect mid-turn, attach catch-up, first answer wins, load refused while running,
  history to the asking device only, resume after a restart).
- `scripts/acp-lab.sh up`: the bridge on `ws://127.0.0.1:18765` (token `labtoken`) in front of the
  Hermes lab's `hermes acp` 0.22.7 and stub model, on loopback.
- `EchoUITests/AcpUITests` (with the lab up; skipped without it): setup through its own screen,
  then a chat with a reply, a command that asks first answered from the card, the chat in the
  list, and the chat after a relaunch.
- `EchoTests/AcpTests`: decoding and mapping, from frames recorded off `hermes acp` 0.22.7.

## Later

- ACP v2 when it leaves draft: `session/resume` with `replayFrom` replaces `session/load`, the
  `state_update` lifecycle, `tool_call` folded into `tool_call_update`. A planned migration.
- `elicitation` forms as answer cards; `diff` content as a diff view; slash commands.
- Several agents in one chat (a room across Hermes, Claude Code, Codex), through the bridge.
- OpenClaw: check what its ACP mode exposes before writing a Gateway v4 client.
