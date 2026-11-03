---
title: A Hermes setup to start from
---

# A Hermes setup to start from

A setup that works well with Redde, on a stock Hermes 0.22 with no patches. Take the parts you want; nothing here is required to use Redde.

## The shape

- **One machine runs Hermes** (a small Linux box), another runs the models (a Mac with Apple
  silicon). They talk over a private network such as Tailscale; so does the iPhone, so Redde works
  away from home without opening a port.
- **Hermes serves two connections**, and Redde can use both:
  - the **Dashboard** (`hermes serve` / Hermes Desktop's login): bots, group chats, Kanban, plugins,
    phone tools, files, approvals as cards. Save this login in Redde even if you chat over the API.
  - the **Hermes API** (`API_SERVER_ENABLED=true`, `API_SERVER_KEY=…`, `API_SERVER_PORT=…` in
    `~/.hermes/.env`, then `hermes gateway run`): plain chat, the Watch, Siri, CarPlay.
- **Profiles are the bots.** The main profile is the everyday agent; each other profile is a bot
  with its own personality, tools, model and memory. Bots made in Redde (New Bot, on the chat list) or in
  Hermes Desktop are the same thing.

## The crew

| Bot | Profile | Job | Tools |
|---|---|---|---|
| Hermes | main | Everyday questions, calendar, notes, plans, schedules | web, memory, calendar MCP, skills, Kanban, cron. **No terminal** |
| Ops | `ops` | The house and the server: Home Assistant, containers | Home Assistant plugin, terminal, web |
| Research | `research` | Looking things up properly | web only |
| Coder | `coder` | Code changes in one project folder | terminal and files, in that folder |

Why split it: a local model with every tool in its prompt is slow and gets confused about which
tool to use. Small bots with few tools answer faster, and "ask Ops" keeps server work out of
everyday chats. In Redde, `@Ops turn off the porch light` from the main chat hands it over; a
group chat with Research and Hermes plans a trip together.

Give each bot only its tools (Redde: Edit Bot → Tools; Hermes: `platform_toolsets` in the
profile's config.yaml, `agent.disabled_toolsets` to take some away). To see what a profile's prompt
costs before you chat: `hermes -p <profile> prompt-size`.

## Permissions

In each profile's `config.yaml`:

```yaml
approvals:
  mode: manual        # dangerous commands wait for you (Redde shows a card, in plain words)
  timeout: 300        # seconds before an unanswered approval is refused
```

- The main agent has **no terminal**. Anything on the server goes to Ops, whose approvals you
  see as cards in Redde.
- Hermes's smart policy lets harmless commands (`ls`, `cat`) run and asks for the rest; add paths
  you never want touched under `approvals.deny`.
- Redde's **Before Acting** (Settings → Agent) sets how much each bot may do on its own: Ask Me
  First, Small Things Are Fine, or Act, Tell Me After.
- Keys never go in a chat. When an agent needs one, it asks in Redde (Keys Asked For) and what you
  paste goes sealed into that profile's `.env`.

## Models

- **Local, on a Mac:** llama-swap in front of a mixture-of-experts model such as Qwen3.6-35B-A3B
  (builds for Apple silicon exist), 128K context, thinking off (it slows every reply).
  A mixture-of-experts model reads Hermes's ~30K-token prompt in about a minute on a Mac; a dense
  model of similar size can take several times longer. After that, replies start in under a second
  because the prompt stays cached. (If you haven't tried Splash or Kapitsa, do!)
- **A small model for chores:** Hermes's compression, titles and other helper jobs run on a 4B
  model so they don't evict the main one (`auxiliary` blocks in config.yaml).
- **llama-swap tip:** add a stop string for Hermes's out-of-band message marker
  (`[Out-of-band message`) under the model's `filters.setParams.stop`, or a small model may write a
  fake next turn from you.
- Any OpenAI-compatible endpoint works the same way under `custom_providers`; Redde lists the
  models from there.

## Tools worth turning on

- **Web search:** the `web` toolset with a search backend (SearXNG self-hosted, or Tavily).
- **Memory:** an MCP memory server (Basic Memory works well) instead of only Hermes's MEMORY.md.
- **Calendar:** a calendar MCP on a machine that has your calendars; Redde's calendar cards and
  Leave-By Alerts use the same events. Or Redde's phone tools read the iPhone's calendars (only the
  ones chosen in Settings → Agent → Calendars).
- **Schedules:** Hermes 0.22 hides some tools until the agent searches for them. So the agent can
  set reminders and routines without fumbling, keep `cronjob_manage` out of the deferred list:

  ```yaml
  tools:
    tool_search:
      defer: [computer_use, session_search, image_generate, todo_list, process_manage, browser_vault]
  ```

  (An explicit list replaces Hermes's default one, so list everything you still want deferred.)
- **Home Assistant:** the `homeassistant` catalog plugin, on the Home bot only.

## The Redde plugin

`hermes plugins install goosehouse-llc/redde/companion/hermes-plugin/redde-push --enable`, or let
Redde do it: Settings → Agent → Ahead of Your Day installs or updates it and turns on the daily
jobs. It brings notifications while Redde is closed, answer cards, Morning Ideas, heads-ups,
watches, goals, phone tools and email.

Two things that bite:
- **Every profile has its own copy of a plugin.** After an update, update each bot's copy too
  (`hermes -p <profile> plugins install … --force`).
- **Restart both services after a plugin change:** the gateway (Hermes API) *and* the Dashboard.
  A CLI install reloads only the gateway; Dashboard chats keep the old plugin until it restarts.

## Things to avoid

- Hermes's **email platform** is a chat channel over a separate address, and it marks every
  existing message as read when it starts: never point it at your own inbox. For your inbox, use
  Redde's email (Settings → Agent → Email).
- Don't give one bot every tool "just in case": prompt size is speed on a local model.
- Changing the main model mid-chat on a local box swaps it out for everyone; keep one main model
  loaded and give bots models that fit alongside it.
