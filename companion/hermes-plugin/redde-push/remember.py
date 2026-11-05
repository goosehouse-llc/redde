"""Remember that… / Forget that… (2.4, "memory you can see"): a short note, only on a message that
asks the agent to remember or forget something, saying how to use Hermes's own memory tool, so
what it keeps is one clean entry Redde's Memory page can show, and a forget really removes it.

Not "remember to …" (a reminder: `cards`'s reminder note), not "do you remember …" (a question),
not "forget it" (said in passing). Nothing on any other turn."""
from __future__ import annotations

import re

_LEAD = r"^\s*(?:(?:ok(?:ay)?|hey|so|and|also|oh)[,.!]?\s+)*(?:\w+[,:]\s+)?(?:please\s+|can you\s+|could you\s+|i want you to\s+)?"
#: "Remember that I'm vegetarian", "Remember: …", "please remember my sister is Ana",
#: "Don't forget that …", "Keep in mind that …", and Redde's own "Remember that: …".
_REMEMBER = re.compile(_LEAD + r"(?:remember|don'?t forget|do not forget|keep in mind|make a note)\b"
                       r"(?!\s+(?:to|when|how|what|where|who|why|if|the time)\b)"
                       r"(?:\s+(?:that|this|these|my|i|i'm|we|our|me)\b|\s*:)", re.IGNORECASE)
#: "Forget that I …", "Forget my old address", "stop remembering …", "remove … from your memory".
_FORGET = re.compile(_LEAD + r"(?:(?:forget|stop remembering|don'?t remember|do not remember|unlearn)\b"
                     r"(?!\s+(?:it|about it|that happened|you saw)\s*[.!]?\s*$)"
                     r"(?:\s+(?:that|this|these|what|about|my|i|i'm|we|our|everything)\b|\s*:)"
                     r"|remove\b.{1,80}\bfrom (?:your )?memory\b)", re.IGNORECASE)

REMEMBER_NOTE = ("[Redde: asked to remember something. Save it now with your memory tool: target 'user' for a fact about "
                 "the person (who they are, what they like, how they want things), 'memory' for anything else. One short, "
                 "self-contained entry; if an entry already says it, replace that entry instead of adding another. Then "
                 "answer in one line saying what you kept.]")
FORGET_NOTE = ("[Redde: asked to forget something. Find the memory entry that says it (target 'user' or 'memory') and "
               "remove it with your memory tool (action remove, old_text copied from that entry); if only part of an "
               "entry should go, replace the entry without it. Then answer in one line saying what you removed, or that "
               "you had nothing like it.]")


def _text(message) -> str:
    if isinstance(message, str):
        return message
    if isinstance(message, list):
        return " ".join(str(p.get("text") or "") for p in message if isinstance(p, dict))
    return ""


def turn_note(message, platform: str = "") -> str | None:
    """For `pre_llm_call`: the note for a message that asks to remember or forget; nil for any
    other message, a scheduled run, a subagent or a bot's turn in a group chat."""
    if platform in ("cron", "subagent", "bot_room"):
        return None
    text = _text(message)
    if not text or text.lstrip().startswith("["):
        return None
    if _FORGET.search(text):
        return FORGET_NOTE
    if _REMEMBER.search(text):
        return REMEMBER_NOTE
    return None
