# Redde Calendar MCP

Gives your Hermes agent your calendar without giving Hermes your Apple account. A tiny server on
a Mac that already syncs your iPhone's calendars through iCloud, which exposes them as MCP tools
over the tailnet. Neither the Redde app nor Hermes needs changes.

## Tools

| Tool | What it does |
|------|--------------|
| `get_agenda` | The schedule for a day or several, grouped by day. Takes `today`, `tomorrow`, a weekday name or a date. The tool agents should reach for first |
| `list_calendars` | Every calendar on the Mac, with ids, and whether it's hidden from the agenda |
| `list_events` | Event summaries in a range: title, times, calendar, location, attendee count. Takes `date` and `days`, or `start` and `end`. Defaults to now through the next 7 days |
| `search_events` | Text search over title, location and notes. Defaults to 30 days back, 180 ahead |
| `get_event` | One event in full, with attendees and notes. Takes an id, or a title and day straight from the agenda |
| `find_free_time` | Open slots inside working hours. Skips all-day events, events marked free and hidden calendars |
| `create_event` | Adds one event. Only offered when installed with `--allow-writes`. Rejects past dates and events over 14 days, and returns the existing event instead of a copy when the same title already starts at that time. It can't invite attendees |

Dates can be ISO 8601 with an offset, local times such as `2026-09-20T14:00` or `2026-09-20`, or
the words `today`, `tomorrow`, `yesterday` and weekday names. A date-only `end` includes that whole
day. Results use the Mac's time zone and include the current local time, so the agent never has to
work out what day it is.

Every result comes back as Markdown for the agent to read: headings per day, one line per event,
attendees and notes under their own headings. Titles and locations are flattened to one line and
notes are quoted, with HTML from Google and Outlook invites turned into plain text, so text in an
invite can't pose as part of the server's own answer. The same data is also returned as JSON in
`structuredContent` for clients that want it.

## Hidden calendars

Sports schedules, holidays and birthdays would crowd an agenda and block free time, so these are
hidden from `get_agenda` and `find_free_time`:

- subscription and birthday calendars
- any calendar with "holiday" in its title
- calendars named in `~/Library/Application Support/Redde Calendar MCP/settings.json`

```json
{ "hide_calendars": ["Team Schedule", "School Lunch Menu"] }
```

The file is read on every call, so edits apply without a restart. The agenda reports how many
events it left out, and `include_hidden: true` brings them back. `list_events` and
`search_events` never hide anything.

## Safety

- **Read-only by default.** `create_event` doesn't exist unless you opt in.
- **No edits or deletes, ever.** There is no tool that changes or removes an event, and the code never calls EventKit's remove. With writes on, the agent can only add.
- **Tailnet only.** Connections from outside 100.64.0.0/10, fd7a:115c:a1e0::/48 and loopback are dropped before any bytes are read.
- **Bearer token.** 32 random bytes, stored with mode 0600 in `~/Library/Application Support/Redde Calendar MCP/token`, compared in constant time.
- **Untrusted text.** Event titles and notes come from whoever sent the invite. The server tells the agent to treat them as data, but a prompt injection in an invite can still reach the model. Keep write tools and outbound tools in mind when you decide what else the agent can do.
- **Bounded.** At most 400 days per query, 500 events per result, notes cut at 1,000 characters.

## Install

Needs Xcode's Swift toolchain on macOS 14 or later.

```sh
./install.sh                 # read-only
./install.sh --allow-writes  # also offer create_event
./install.sh --uninstall
```

The script builds a release binary and wraps it in `~/Applications/Redde Calendar MCP.app`. It
signs the app, then runs it at login with a LaunchAgent that restarts it if it exits. The first run
asks for Calendar access. If you miss the prompt, allow it in System Settings, Privacy & Security,
Calendars.

Signing uses the first Apple Development or Developer ID identity in your keychain. Override with
`SIGN_IDENTITY=<name or SHA-1>`. A stable identity keeps the Calendar permission across rebuilds.
`PORT` changes the port from 8765.

The log is `~/Library/Logs/redde-calendar-mcp.log`.

It starts when you log in, not at boot. macOS only lets an app read Calendar inside a logged-in
session, so a boot-time daemon can't do this job. For a Mac that should come back on its own after
a restart, turn on automatic login in System Settings, Users & Groups (FileVault must be off). To
power back on after an outage, run `sudo pmset -a autorestart 1`.

## Connect Hermes

Print the token on the Mac:

```sh
~/Applications/Redde\ Calendar\ MCP.app/Contents/MacOS/redde-calendar-mcp --print-token
```

On the Hermes host, add the server to `~/.hermes/config.yaml` and restart the gateway:

```yaml
mcp_servers:
  calendar:
    url: "http://<mac tailnet address>:8765/mcp"
    headers:
      Authorization: "Bearer <token>"
```

The tools appear to the agent as `mcp_calendar_list_events` and so on.

Hermes decides how the agent formats its replies from a per-client hint, not from tool results. Redde's
serve connection identifies as `mobile`, which has no built-in hint, and the API server's built-in
hint asks for no Markdown at all. To get Markdown answers in Redde, add this to the same config file:

```yaml
platform_hints:
  mobile:
    append: >-
      You're talking through Redde, an iPhone app that renders Markdown: headings, bold, bullet and
      numbered lists, tables, code blocks and Mermaid diagrams. Use Markdown whenever it makes an
      answer easier to scan, such as a schedule, a list of steps or a comparison. Keep short
      conversational replies as plain sentences. Redde strips formatting before speaking a reply.
``` To rotate the token, delete
the token file and run the install script again, then update the Hermes config.

## Protocol

MCP Streamable HTTP with JSON responses, no server-sent event stream. POST to `/mcp` carries
JSON-RPC, notifications get 202, GET gets 405. Protocol versions 2024-11-05 through 2025-11-25.
Tested with the official Python SDK, mcp 2.0.
