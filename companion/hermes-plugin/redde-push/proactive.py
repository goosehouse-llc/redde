"""How much the agents bring up on their own (1.58.0): one dial for every agent, after the
proactivity setting of Meta's Muse (asked 2026-11-27, "now build the muse gaps"). Kept in the main
home; Settings › Your Day › Agents Bring Up sets it.

- **off**: nothing on their own. Idea cards, Follow-Through's cards, Days Out, usual buys,
  appointments and what's new on Jellyfin aren't sent (Follow-Through still keeps its list), and
  the runs that are only there to suggest things (Morning Ideas, Routine Suggestions, Gone Quiet)
  end before any model is called. A card that asks to be heard ("now": a sign-in that may not be
  them, a plan they made, at its time) still comes.
- **less**: only what matters soon: cards marked "now" or "look", and Follow-Through's money,
  travel and date-bound kinds; at most one set of ideas a day from each agent, and the runs that
  offer ideas are told to clear a high bar or offer nothing.
- **normal**: as before.
- **more**: the runs that offer ideas may offer more, nice-to-know ones too, and an agent's ideas
  left alone go quiet later.

What they asked for is never touched: replies, reminders, briefings, Heads-Ups, watches, mail
rules, approvals and questions."""
from __future__ import annotations

import json
import re
from pathlib import Path

LEVELS = ("off", "less", "normal", "more")
FILE = "proactive.json"

#: Follow-Through's kinds that still come at "less": money, travel, a date, someone's account.
SOON = frozenset({"security", "planned", "meeting", "bill", "trial", "expiry", "trip", "bounce"})

#: The runs there only to suggest things, which "off" ends with no model call: by job name, and Gone
#: Quiet's mark at the start of its prompt (silence.py).
SUGGESTING = ("[redde] Morning ideas", "[redde] Routine suggestions")
_QUIET = re.compile(r"^\s*\[redde-quiet:\d{1,3}h\]", re.I)

#: How many idea sets an agent may send in a day at "less".
LESS_PER_DAY = 1
#: Sets of ideas left alone before they go quiet, by level ("normal" is ideas.IGNORED).
IGNORED_AT = {"more": 6}

LESS_NOTE = ("[Redde: they asked agents to bring up less on their own. Offer an idea only if it matters to them in "
             "the next day or two and they'd be sorry to miss it; two at most. If nothing clears that bar, offer "
             "nothing.]")
MORE_NOTE = ("[Redde: they like hearing ideas. Up to five, nice-to-know ones too, as long as each is about their own "
             "life and something they could act on.]")
REFUSED = ("They've asked agents not to send ideas on their own (Agents Bring Up is Off in Redde). If they asked you "
           "for ideas just now, give them in your reply; otherwise leave it, and don't mention it.")
ONE_A_DAY = ("You've already sent them ideas today, and they asked agents to bring up less on their own: keep this "
             "for tomorrow's set, or leave it.")


def level(home: Path) -> str:
    """The dial, "normal" when never set."""
    try:
        said = json.loads((Path(home) / "redde-push" / FILE).read_text()).get("level")
    except Exception:
        return "normal"
    return said if said in LEVELS else "normal"


def set_level(home: Path, value: str) -> bool:
    if value not in LEVELS:
        return False
    path = Path(home) / "redde-push" / FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".new")
    tmp.write_text(json.dumps({"level": value}))
    tmp.replace(path)
    return True


def card_allowed(dial: str, kind: str = "", mark: str = "") -> bool:
    """Whether a card Redde made itself (Follow-Through and the like) goes out at this level."""
    if dial == "off":
        return mark == "now"
    if dial == "less":
        return mark in ("now", "look") or kind in SOON
    return True


def ideas_refused(dial: str, mark: str, sent_today: int) -> str | None:
    """Why an agent's set of ideas doesn't go, or None."""
    if mark == "now":
        return None
    if dial == "off":
        return REFUSED
    if dial == "less" and sent_today >= LESS_PER_DAY:
        return ONE_A_DAY
    return None


def ignored_before_quiet(dial: str, standard: int) -> int:
    return IGNORED_AT.get(dial, standard)


def stands_down(dial: str, job: dict) -> bool:
    """A scheduled run that is there only to suggest things, at "off"."""
    if dial != "off":
        return False
    name, prompt = str((job or {}).get("name") or ""), str((job or {}).get("prompt") or "")
    return name.startswith(SUGGESTING) or bool(_QUIET.match(prompt))


def run_note(home: Path, message, platform: str = "") -> str | None:
    """For `pre_llm_call`: a scheduled run that offers ideas, told the bar at "less" or "more"."""
    if platform != "cron":
        return None
    dial = level(home)
    if dial not in ("less", "more"):
        return None
    from .ideas import TOOL
    text = message if isinstance(message, str) else " ".join(
        str(p.get("text") or "") for p in message or [] if isinstance(p, dict)) if isinstance(message, list) else ""
    if TOOL not in text and "IDEA:" not in text:
        return None
    return LESS_NOTE if dial == "less" else MORE_NOTE


def slash(home: Path, words: list[str]) -> str:
    """`proactive`: the dial; `proactive set off|less|normal|more`."""
    if words[:1] == ["set"] and len(words) == 2:
        if not set_level(home, words[1]):
            return f"redde-push refused: one of {', '.join(LEVELS)}"
    return f"redde-push proactive {level(home)}"
