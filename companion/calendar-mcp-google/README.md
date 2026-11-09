# Redde Calendar for Google

The same calendar tools as the Mac server in `../calendar-mcp` (`get_agenda`, `list_calendars`,
`list_events`, `search_events`, `get_event`, `find_free_time`, `create_event`), with the same
answers, so Redde's calendar cards and an agent's habits work with either. This one reads Google
Calendar directly, so it can run on the Hermes host itself, and the calendar keeps working when no
Mac is awake.

- **Python 3.10 or newer, standard library only.** Nothing to install.
- **Read-only unless `--allow-writes`.** With it, agents can add events. Nothing can be edited or
  deleted through this server.
- **Answers loopback and tailnet addresses only**, with a bearer token. Default `127.0.0.1:8766`, so
  only the machine it runs on can reach it.
- **The narrowest Google access that works:** events (read and add) and the calendar list (read).
  No mail, no contacts, no Drive.
- **No reminders.** Apple Reminders need a Mac or an iPhone: keep the Mac server for those (its
  `list_reminders`, `create_reminder`, `complete_reminder`), or Redde's phone tools.

## Files

Everything lives in one folder, `~/.config/redde-calendar-google` (or `$REDDE_GCAL_HOME`), readable
only by the account the server runs as:

| File | What it is |
|---|---|
| `client.json` | The OAuth client you download from Google Cloud (below) |
| `accounts/<name>.json` | One per Google account signed in: its refresh token |
| `token` | The bearer token Hermes sends; made on first run (`server.py --print-token`) |
| `settings.json` | Optional, read on every call: see below |

```json
{ "hide_calendars": ["Team Schedule"],
  "never_show": ["Diary"],
  "read_only": ["Work"],
  "default_calendar": "Personal",
  "time_zone": "America/New_York" }
```

- `hide_calendars` keeps a calendar out of the agenda and free time unless asked for. Google's own
  holiday, sports and birthday calendars, and calendars added by URL, are always treated this way.
- `never_show` hides a calendar from every tool.
- `read_only` stops events being added to it.
- `default_calendar` is where `create_event` adds when no calendar is named (otherwise the primary
  calendar).
- `time_zone` overrides the default calendar's own time zone.

Names match a calendar's title, its Google id, `<account>/<id>`, or a whole account's name.

## Set it up

### 1. Make a Google OAuth client (once)

1. In [Google Cloud](https://console.cloud.google.com), make a project (any name).
2. Go to **APIs & Services → Library**, find **Google Calendar API** and press **Enable**.
3. Open **Google Auth Platform** and press **Get started**:
   - give it an app name and your email;
   - for Audience pick **External**;
   - finish.
4. Under **Audience**, press **Publish app** so its status is **In production**. An app left in
   Testing loses its sign-in every 7 days. It doesn't need Google's review for your own accounts:
   Google warns "Google hasn't verified this app" when you sign in, and you go on with **Advanced →
   Go to … (unsafe)**.
5. Under **Clients**, press **Create client** and pick **Desktop app**. Download its JSON and save it
   as `client.json` in the server's folder (mode 0600).

### 2. Sign in

```sh
python3 sign_in.py personal
```

The name (`personal` here) is how the account shows in `list_calendars`. Open the link it prints on
any device and allow both calendar permissions. The page after that won't load, and that's expected:
copy its whole address back into the terminal. Repeat with another name for each further account.
A running server picks a new account up within five minutes.

### 3. Run it

```sh
python3 server.py --allow-writes        # listens on 127.0.0.1:8766
```

Run it as a systemd user service (`systemctl --user`) or a LaunchAgent, so it starts at login and
restarts if it stops.

### 4. Tell Hermes

In `config.yaml`, with the token in the profile's `.env` as `GCAL_MCP_TOKEN`:

```yaml
mcp_servers:
  calendar:
    url: http://127.0.0.1:8766/mcp
    headers:
      Authorization: Bearer ${env:GCAL_MCP_TOKEN}
```

To keep Apple Reminders from the Mac server, add it under another name, with only its reminder
tools:

```yaml
  reminders:
    url: http://<mac>:8765/mcp
    headers:
      Authorization: Bearer ${env:CALENDAR_MCP_TOKEN}
    tools:
      include: [list_reminders, create_reminder, complete_reminder]
```

## Tests

```sh
python3 -m unittest discover -s companion/calendar-mcp-google/tests
```

They run against a pretend Google, so they need no account or network.
