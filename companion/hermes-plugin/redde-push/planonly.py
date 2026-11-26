"""A reply that was only the plan (1.49.0, 2026-11-26). With its thinking turned off, a model can
write what it means to do as its answer and stop there: Sol, on "We're going mini golfing today",
answered "Robin's letting me know they're going mini golfing today — just sharing an update. This is a
conversational remark, not a task request. Let me respond warmly… No tools needed — just an
appropriate conversational response." and nothing else; and on 2026-11-25, "Robin wants "Muppets
Christmas Carol" added to the Christmas Movies list… Let me add it" without adding it.

Hermes asks the model to go on when a short reply ends on an announced next step (its stall guard:
"let me now…", 400 characters at most), but these don't end that way, and a model call can't be
made twice from a plugin (llm_execution middleware is single-use). So the middleware (`turn`)
ends such a reply on "Let me now do that.": Hermes's stall guard then shows it as working text (its
`message.interim`), asks once more ("[System: Continue now. …]"), and the model does it or answers.

Only once a turn, only for a call that offers tools (the guard needs them), and only with
`agent.stall_guards` on (Hermes's default); anything else is left as it came.

A scheduled run's plan to say nothing is the other shape: "…I'll respond [SILENT] since everything
is plainly handled." (2026-11-13) was delivered, plan and all, as Hermes keeps a run quiet only for
"[SILENT]" alone or on a line of its own. Such a run's answer becomes "[SILENT]", with no model.
"""
from __future__ import annotations

import logging
import re
import threading
import time

log = logging.getLogger("redde_push")

SUFFIX = "Let me now do that."
#: Hermes's stall guard looks at replies this long at most (`_TRAILING_CONTINUE_INTENT_MAX_CHARS`).
GUARD_MAX = 400
#: A plan is short; a long reply that mentions one is an answer.
LONGEST = 1200

# Quoted words aren't the reply's own: "can you add…" said back, a title, a `when` field.
_QUOTED = re.compile(r"\"[^\"\n]{0,200}\"|“[^”\n]{0,200}”|`[^`\n]{0,200}`")
# Speaking to them: a reply. A plan speaks of them.
_YOU = re.compile(r"(?i:\byou(?:r|rs|rself|['’](?:re|ll|d|ve))?\b)")
# Opening on them, in the third person: "Robin's letting me know…", "Robin wants…", "The user is asking…".
_ABOUT_THEM = re.compile(
    r"^\s*(?i:(?:okay|ok|alright|so)[,.]?\s+)?(?:(?i:the user|user)|[A-Z][\w'’-]{1,24})(?:['’]s)?\s+"
    r"(?i:(?:is|was|just|has|now|also|really)\s+)?"
    r"(?i:wants?|asking|asked|asks|letting me know|lets me know|telling me|told me|tells me|mention(?:s|ed|ing)|"
    r"sharing|shared|shares|said|says|saying|wonder(?:s|ed|ing)|would like|needs?|request(?:s|ed|ing)|going|heading|"
    r"planning|looking for|interested in|reporting|confirm(?:s|ed|ing)|checking in|greeting|thank(?:s|ed|ing)|"
    r"leaning|hoping|trying|replying|responding|answering|following up|giving me)\b")
# Or on what to do about it: "Let me respond…", "This is a conversational remark…".
_META_OPENING = re.compile(
    r"^\s*(?i:let me (?:respond|reply|think|see|assess|check|look|figure)|"
    r"i (?:should|need to|will|['’]ll|want to) (?:respond|reply|answer|acknowledge|check|look)|"
    r"this is (?:a|an|just a|just an) (?:conversational|casual|simple|friendly|quick|social|light))\b")
# A plan in it: what it says it'll do.
_PLAN = re.compile(
    r"(?i:(?:^|[.!?\n—–:;]\s*|\band\s+|\bso\s+)(?:let me|let['’]s|i['’]ll|i will|i should|i need to|i['’]m going to|"
    r"i am going to|time to|now i['’]ll)\s+(?:just\s+|now\s+|quickly\s+|go ahead and\s+|first\s+)?"
    r"(?:respond|reply|answer|acknowledge|add|put|set|schedule|create|make|check|look|find|search|update|remove|delete|"
    r"mark|move|send|call|use|read|get|pull|write|draft|give|tell|keep|confirm|note|save|log|book|offer|suggest|share|"
    r"wish|congratulate|greet|thank|ask|start|run|fetch|see)\b)")
# Or a note to itself: "No tools needed", "just an appropriate conversational response".
_META = re.compile(
    r"(?i:\bno tools? (?:are |is )?(?:needed|required|necessary)\b|"
    r"\b(?:conversational|casual|social) (?:remark|message|update|comment|exchange|note|check-in|greeting)\b|"
    r"\bnot a (?:task|request|question)\b|\bjust sharing\b|"
    r"\b(?:warm|brief|short|friendly|appropriate|natural|conversational) (?:response|reply|acknowledg(?:e)?ment)\b|"
    r"\brespond (?:warmly|briefly|naturally|kindly|accordingly|appropriately)\b)")
# A scheduled run's plan to say nothing: "I'll respond [SILENT] since…", "I answer exactly [SILENT]."
_SILENT_PLAN = re.compile(r"(?i:\b(?:respond|reply|answer)(?:\s+(?:with|exactly|only))*\s+\[SILENT\])")
_SENTENCES = re.compile(r"[^.!?\n]+[.!?]*")


def _kept_quiet(text: str) -> bool:
    """Hermes keeps a scheduled run quiet already: "[SILENT]" alone, or as its first or last line."""
    lines = [line.strip() for line in str(text or "").splitlines() if line.strip()]
    return bool(lines) and (lines[0].upper() == "[SILENT]" or lines[-1].upper() == "[SILENT]")


def silent_plan(text: str) -> bool:
    """Whether a scheduled run's answer is its plan to say nothing, not the "[SILENT]" itself."""
    t = str(text or "").strip()
    return bool(t) and not _kept_quiet(t) and bool(_SILENT_PLAN.search(t))


def only_a_plan(text: str) -> bool:
    """Whether a finished reply is only what the model meant to do, not the reply itself."""
    t = str(text or "").strip()
    if not t or len(t) > LONGEST or _kept_quiet(t):
        return False
    bare = _QUOTED.sub(" ", t)
    if _YOU.search(bare):
        return False
    if _ABOUT_THEM.match(bare):
        return bool(_PLAN.search(bare) or _META.search(bare))
    if _META_OPENING.match(bare):
        # "Let me check if 391 is prime. 391 = 17 × 23 …" is an answer: a plan ends on one.
        last = (_SENTENCES.findall(bare) or [""])[-1].strip()
        return bool(_META.search(bare) or _PLAN.match(last))
    return False


def ended(plan: str) -> str:
    """The plan, ending where Hermes's stall guard takes it up: on "Let me now do that.", within its
    length (a long plan shortened at a sentence, the start kept)."""
    body = str(plan or "").strip()
    room = GUARD_MAX - len(SUFFIX) - 4
    if len(body) > room:
        cut = body[:room - 1]
        stop = max(cut.rfind(". "), cut.rfind("! "), cut.rfind("? "), cut.rfind("\n"))
        body = (cut[:stop + 1] if stop > room // 3 else cut).rstrip() + "…"
    return body + "\n\n" + SUFFIX


def _stall_guards_on() -> bool:
    try:
        from hermes_cli.config import load_config_readonly
        agent = (load_config_readonly() or {}).get("agent") or {}
        return bool(agent.get("stall_guards", True)) if isinstance(agent, dict) else True
    except Exception:
        return True


class PlanOnly:
    """The middleware, innermost: it sees the provider's own answer."""

    def __init__(self, guards_on=_stall_guards_on):
        self.guards_on = guards_on
        self._seen: dict[str, float] = {}   # turns already handed on once
        self._lock = threading.Lock()

    def turn(self, request=None, next_call=None, **context):
        response = next_call(request)
        try:
            api_mode = str(context.get("api_mode") or "")
            if api_mode and api_mode != "chat_completions":
                return response
            choice = (getattr(response, "choices", None) or [None])[0]
            message = getattr(choice, "message", None)
            if choice is None or message is None or getattr(choice, "finish_reason", None) != "stop":
                return response
            if getattr(message, "tool_calls", None):
                return response
            content = getattr(message, "content", None)
            if not isinstance(content, str):
                return response
            if str(context.get("session_id") or "").startswith("cron_") and silent_plan(content):
                message.content = "[SILENT]"
                log.info("redde-push: a scheduled run's plan to say nothing (%d chars) answered [SILENT] (session %s)",
                         len(content), context.get("session_id") or "")
                return response
            if not only_a_plan(content):
                return response
            if not isinstance(request, dict) or not request.get("tools"):
                return response   # no tools offered: Hermes's guard doesn't ask again
            key = str(context.get("turn_id") or context.get("session_id") or "")
            with self._lock:
                now = time.time()
                self._seen = {k: t for k, t in self._seen.items() if now - t < 3600}
                if key in self._seen:
                    return response
                self._seen[key] = now
            if not self.guards_on():
                return response
            message.content = ended(content)
            log.info("redde-push: a reply that was only its plan (%d chars) left for Hermes to take up (session %s)",
                     len(content), context.get("session_id") or "")
        except Exception:
            log.debug("redde-push: looking at a plan-only reply failed", exc_info=True)
        return response
