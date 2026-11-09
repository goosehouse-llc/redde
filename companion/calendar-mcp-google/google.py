"""Google Calendar for the Redde calendar server: signing in, keeping the access fresh, and the few
calls the tools need (the calendar list, events in a range, one event, adding one). Standard
library only, so it runs on any Hermes host's Python with nothing to install.

Everything lives in one folder, readable only by the account the server runs as
(`~/.config/redde-calendar-google` unless REDDE_GCAL_HOME says otherwise):

    client.json            the OAuth client ("Desktop app") downloaded from Google Cloud
    accounts/<name>.json   one per Google account signed in: its refresh token, never printed
    token                  the bearer token Hermes sends this server
    settings.json          optional: hide_calendars, never_show, read_only, default_calendar, time_zone

The scopes are the narrowest that do the job: events (read and add; this server never edits or
deletes) and the calendar list, read only. No mail, no contacts, no Drive.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

SCOPES = ("https://www.googleapis.com/auth/calendar.events",
          "https://www.googleapis.com/auth/calendar.calendarlist.readonly")
AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
API = "https://www.googleapis.com/calendar/v3"
#: Where the browser is sent after Allow. Nothing listens there: the page fails to load, and the
#: person copies its address (which carries the code) back into sign_in.py. That works from any
#: device, whichever machine the server is on.
REDIRECT = "http://127.0.0.1:8099/"


class GoogleError(Exception):
    pass


def home() -> Path:
    return Path(os.environ.get("REDDE_GCAL_HOME") or Path.home() / ".config" / "redde-calendar-google")


def write_private(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix(path.suffix + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as out:
        out.write(text)
    os.replace(temporary, path)


def client() -> dict:
    """The OAuth client: Google's download has it under "installed"."""
    try:
        data = json.loads((home() / "client.json").read_text())
    except (OSError, ValueError) as error:
        raise GoogleError(f"No Google client file at {home() / 'client.json'}: {error}")
    found = data.get("installed") or data.get("web") or data
    if not found.get("client_id") or not found.get("client_secret"):
        raise GoogleError("The Google client file has no client_id or client_secret.")
    return found


def accounts() -> list[str]:
    folder = home() / "accounts"
    return sorted(p.stem for p in folder.glob("*.json")) if folder.is_dir() else []


# ---- signing in (sign_in.py) ---------------------------------------------------------------------

def sign_in_link(state: str, verifier: str) -> str:
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    query = {"client_id": client()["client_id"], "redirect_uri": REDIRECT, "response_type": "code",
             "scope": " ".join(SCOPES), "access_type": "offline", "prompt": "consent", "state": state,
             "code_challenge": challenge, "code_challenge_method": "S256", "include_granted_scopes": "false"}
    return AUTH_URL + "?" + urllib.parse.urlencode(query)


def new_verifier() -> str:
    return secrets.token_urlsafe(64)[:96]


def code_from(pasted: str, state: str) -> str:
    """The code from the address the browser ended on (or the code alone)."""
    pasted = pasted.strip()
    if "code=" not in pasted:
        if pasted and " " not in pasted:
            return pasted
        raise GoogleError("That isn't the address Google sent you to: it has no code in it.")
    query = urllib.parse.parse_qs(urllib.parse.urlparse(pasted).query)
    if query.get("error"):
        raise GoogleError(f"Google said: {query['error'][0]}")
    if query.get("state", [state])[0] != state:
        raise GoogleError("That address is from a different sign-in. Start again.")
    return query["code"][0]


def finish_sign_in(name: str, code: str, verifier: str, post=None) -> dict:
    """Trades the code for a refresh token and keeps it as accounts/<name>.json."""
    c = client()
    answer = (post or _post)(TOKEN_URL, {"code": code, "client_id": c["client_id"], "client_secret": c["client_secret"],
                                         "redirect_uri": REDIRECT, "grant_type": "authorization_code",
                                         "code_verifier": verifier})
    if not answer.get("refresh_token"):
        raise GoogleError("Google gave no refresh token. Remove this app's access at "
                          "myaccount.google.com/permissions and sign in again.")
    granted = set((answer.get("scope") or "").split())
    missing = [s for s in SCOPES if s not in granted]
    if missing:
        raise GoogleError("Calendar access wasn't granted (tick both calendar boxes on Google's page). Sign in again.")
    write_private(home() / "accounts" / f"{name}.json",
                  json.dumps({"refresh_token": answer["refresh_token"], "scopes": sorted(granted), "added": int(time.time())}))
    return answer


# ---- calls ---------------------------------------------------------------------------------------

def _post(url: str, form: dict) -> dict:
    request = urllib.request.Request(url, data=urllib.parse.urlencode(form).encode(), method="POST",
                                     headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(request, timeout=20) as reply:
            return json.loads(reply.read())
    except urllib.error.HTTPError as error:
        try:
            said = json.loads(error.read())
        except ValueError:
            said = {}
        if said.get("error") == "invalid_grant":
            raise GoogleError("invalid_grant")
        raise GoogleError(f"Google sign-in failed: {said.get('error_description') or said.get('error') or error.code}")


class Google:
    """One server's way to Google: an access token per account, refreshed when it runs out.
    `send` is the only way out to the network (swapped in tests)."""

    def __init__(self, send=None, post=None):
        self._send = send or self._urlopen
        self._post = post or _post
        self._tokens: dict[str, tuple[str, float]] = {}
        self._lock = threading.Lock()

    def access(self, account: str) -> str:
        with self._lock:
            kept = self._tokens.get(account)
            if kept and kept[1] > time.time() + 60:
                return kept[0]
            try:
                saved = json.loads((home() / "accounts" / f"{account}.json").read_text())
            except (OSError, ValueError):
                raise GoogleError(f"Google account {account!r} isn't signed in. Run sign_in.py {account}.")
            c = client()
            try:
                answer = self._post(TOKEN_URL, {"client_id": c["client_id"], "client_secret": c["client_secret"],
                                                "refresh_token": saved["refresh_token"], "grant_type": "refresh_token"})
            except GoogleError as error:
                if str(error) == "invalid_grant":
                    raise GoogleError(f"Google's sign-in for {account!r} has expired or was removed. On the server, run "
                                      f"sign_in.py {account} again. (If this happens every week, the Google Cloud app is "
                                      "still in Testing: publish it, see the README.)")
                raise
            self._tokens[account] = (answer["access_token"], time.time() + float(answer.get("expires_in", 3600)))
            return answer["access_token"]

    def call(self, account: str, method: str, path: str, query: dict | None = None, body: dict | None = None) -> dict:
        url = API + path + ("?" + urllib.parse.urlencode(query, doseq=True) if query else "")
        for attempt in (1, 2):
            status, data = self._send(method, url, self.access(account), body)
            if status == 401 and attempt == 1:
                self._tokens.pop(account, None)   # (revoked or expired early: one fresh token, once)
                continue
            if status >= 400:
                message = (data.get("error") or {}).get("message") if isinstance(data, dict) else None
                if status == 404:
                    raise GoogleError("Google has no such event or calendar.")
                raise GoogleError(f"Google Calendar said {status}: {message or 'no reason given'}")
            return data
        raise GoogleError("Google Calendar refused the sign-in.")

    @staticmethod
    def _urlopen(method: str, url: str, token: str, body: dict | None) -> tuple[int, dict]:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method,
                                         headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                                                  **({"Content-Type": "application/json"} if data else {})})
        try:
            with urllib.request.urlopen(request, timeout=20) as reply:
                return reply.status, json.loads(reply.read() or b"{}")
        except urllib.error.HTTPError as error:
            try:
                return error.code, json.loads(error.read() or b"{}")
            except ValueError:
                return error.code, {}

    # The calls the tools use.

    def calendar_list(self, account: str) -> list[dict]:
        found, page = [], None
        while True:
            query = {"minAccessRole": "reader", "maxResults": 250, **({"pageToken": page} if page else {})}
            data = self.call(account, "GET", "/users/me/calendarList", query)
            found += data.get("items") or []
            page = data.get("nextPageToken")
            if not page:
                return found

    def events(self, account: str, calendar: str, start: str, end: str, limit: int = 2500) -> list[dict]:
        found, page = [], None
        while len(found) < limit:
            query = {"timeMin": start, "timeMax": end, "singleEvents": "true", "orderBy": "startTime",
                     "maxResults": 2500, "showDeleted": "false", **({"pageToken": page} if page else {})}
            data = self.call(account, "GET", f"/calendars/{urllib.parse.quote(calendar, safe='')}/events", query)
            found += data.get("items") or []
            page = data.get("nextPageToken")
            if not page:
                break
        return found[:limit]

    def event(self, account: str, calendar: str, event: str) -> dict:
        return self.call(account, "GET", f"/calendars/{urllib.parse.quote(calendar, safe='')}/events/{urllib.parse.quote(event, safe='')}")

    def insert(self, account: str, calendar: str, body: dict) -> dict:
        return self.call(account, "POST", f"/calendars/{urllib.parse.quote(calendar, safe='')}/events", body=body)
