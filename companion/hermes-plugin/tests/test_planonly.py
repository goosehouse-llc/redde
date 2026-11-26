"""python -m unittest discover -s companion/hermes-plugin/tests

A reply that was only the plan (1.49.0, 2026-11-26): with its thinking off, Sol answered "We're
going mini golfing today" with what it meant to do, and stopped; on 2026-11-25 it said it would add a
film to a list and didn't. The texts below are those replies (names changed). Tried on 3,524 stored
replies, it took these four and nothing else."""
import importlib
import re
from pathlib import Path
import unittest
from types import SimpleNamespace

from test_cards import plugin

planonly = importlib.import_module(plugin.__name__ + ".planonly")

MINI_GOLF = ("Robin's letting me know they're going mini golfing today — just sharing an update. This is a conversational "
             "remark, not a task request. Let me respond warmly and pleasantly. It's Thanksgiving Day (Thursday, 26 November "
             "2026).\n\nNo tools needed — just an appropriate conversational response.")
FILM = ("Robin wants \"Muppets Christmas Carol\" added to the Christmas Movies list, scheduled for Dec 5 at 9 PM. Let me add "
        "it with the `when` date/time.\n\nDec 5, 2026 at 9 PM EST = 2026-12-05T21:00:00-05:00.")
QUIET = ("Let me assess the state of the three items from the follow-up:\n\n1. **Car payment due today**: the reminder was "
         "completed.\n\nAll three are handled. There's nothing new to offer.\n\nI'll respond [SILENT] since everything is "
         "plainly handled.")
EMPTY_INBOX = ("The five target buckets are all empty. No archiving was needed. Per the instructions, when the inbox is "
               "completely empty across all non-archived buckets, I answer exactly [SILENT].")

# Hermes 0.22.2's stall guard (agent/agent_runtime_helpers.py), the shape `ended` must reach.
TRAILING_CONTINUE_INTENT = re.compile(r"(?:\blet me now\b|\bi(?:['’])?ll now\b|\bi will now\b"
                                      r"|\bnow i(?:['’]ll| will)\b|\bnext[,:] i\b)"
                                      r"[^.!?\n]{0,100}[.:…]?\s*$", re.IGNORECASE)


def reply(content, finish="stop", tool_calls=None):
    message = SimpleNamespace(role="assistant", content=content, tool_calls=tool_calls, reasoning_content=None)
    return SimpleNamespace(id="r1", choices=[SimpleNamespace(index=0, message=message, finish_reason=finish)])


TOOLS = {"messages": [{"role": "user", "content": "hi"}], "tools": [{"type": "function", "function": {"name": "redde_list"}}]}


class PlanOnlyTests(unittest.TestCase):
    def test_the_plans_are_known(self):
        for text in (MINI_GOLF, FILM, "The user is asking about the game tonight. Let me check the calendar.",
                     "This is a casual greeting. No tools needed.", "Robin asked \"can you add milk\". Let me add it.",
                     "Let me respond to this check-in briefly."):
            self.assertTrue(planonly.only_a_plan(text), text)

    def test_answers_are_left_alone(self):
        for text in ("Have fun mini golfing! Watch the weather this afternoon.",
                     "Let me check if 391 is prime.\n\n391 = 17 × 23 = 391. Since it has factors other than 1 and itself, it "
                     "is not prime.",
                     "Added. **The Santa Clause** is now on your Christmas Movies list at #14.",
                     "Robin's leaning toward renaming, so here are grounded alternatives: Lookout, Sentry, Porch Light.",
                     "Robin wants the long version, so here it is. " + "Lots of words. " * 120,
                     "[SILENT]", "Checked the three.\n\n[SILENT]", "", None,
                     "Since there are threads remaining (2, not zero), I answer with the count line — not [SILENT]."):
            self.assertFalse(planonly.only_a_plan(text), text)

    def test_a_scheduled_runs_plan_to_say_nothing(self):
        self.assertTrue(planonly.silent_plan(QUIET))
        self.assertTrue(planonly.silent_plan(EMPTY_INBOX))
        for text in ("[SILENT]", "Nothing new.\n\n[SILENT]", "[SILENT]\n\nNothing new.",
                     "Since there are threads remaining (2, not zero), I answer with the count line — not [SILENT].",
                     "**62 threads remain in the inbox.**"):
            self.assertFalse(planonly.silent_plan(text), text)

    def test_the_plan_ends_where_hermess_stall_guard_takes_it_up(self):
        for plan in (MINI_GOLF, FILM, MINI_GOLF * 3):
            ended = planonly.ended(plan)
            self.assertLessEqual(len(ended), planonly.GUARD_MAX)
            self.assertTrue(TRAILING_CONTINUE_INTENT.search(ended[-160:]), ended)
            self.assertTrue(ended.endswith("\n\nLet me now do that."))
        self.assertEqual(planonly.ended(FILM), FILM + "\n\nLet me now do that.")
        long = planonly.ended(MINI_GOLF * 3)
        self.assertTrue(long.startswith(MINI_GOLF[:200]), "the start of a long plan is kept")


class MiddlewareTests(unittest.TestCase):
    def guard(self, guards_on=True):
        return planonly.PlanOnly(guards_on=lambda: guards_on)

    def test_a_plan_is_left_for_hermes_to_take_up_once_a_turn(self):
        guard = self.guard()
        out = guard.turn(request=TOOLS, next_call=lambda r: reply(FILM), session_id="s1", turn_id="t1",
                         api_mode="chat_completions")
        self.assertEqual(out.choices[0].message.content, FILM + "\n\nLet me now do that.")
        again = guard.turn(request=TOOLS, next_call=lambda r: reply(FILM), session_id="s1", turn_id="t1",
                           api_mode="chat_completions")
        self.assertEqual(again.choices[0].message.content, FILM, "once a turn")
        other = guard.turn(request=TOOLS, next_call=lambda r: reply(MINI_GOLF), session_id="s1", turn_id="t2", api_mode="")
        self.assertTrue(other.choices[0].message.content.endswith("Let me now do that."), "the next turn's")

    def test_what_hermes_wouldnt_take_up_is_left_as_it_came(self):
        cases = (
            (dict(request={"messages": []}, next_call=lambda r: reply(FILM)), "no tools offered"),
            (dict(request=TOOLS, next_call=lambda r: reply(FILM, tool_calls=[{"id": "c1"}])), "a tool call"),
            (dict(request=TOOLS, next_call=lambda r: reply(FILM, finish="length")), "cut off"),
            (dict(request=TOOLS, next_call=lambda r: reply("Have fun out there!")), "an answer"),
            (dict(request=TOOLS, next_call=lambda r: reply(FILM), api_mode="anthropic_messages"), "another API's shape"),
        )
        for kwargs, why in cases:
            kwargs.setdefault("api_mode", "chat_completions")
            out = self.guard().turn(session_id="s1", turn_id="t1", **kwargs)
            self.assertFalse(out.choices[0].message.content.endswith("Let me now do that."), why)
        out = self.guard(guards_on=False).turn(request=TOOLS, next_call=lambda r: reply(FILM), session_id="s1", turn_id="t1")
        self.assertEqual(out.choices[0].message.content, FILM, "agent.stall_guards off")

    def test_a_scheduled_runs_plan_to_say_nothing_is_kept_quiet(self):
        out = self.guard().turn(request={"messages": []}, next_call=lambda r: reply(QUIET),
                                session_id="cron_8071e3378abd_20261113_083059", turn_id="t1", api_mode="chat_completions")
        self.assertEqual(out.choices[0].message.content, "[SILENT]")
        chat = self.guard().turn(request=TOOLS, next_call=lambda r: reply(QUIET), session_id="20261113_083059_ab12cd", turn_id="t1")
        self.assertNotEqual(chat.choices[0].message.content, "[SILENT]", "only a scheduled run's")

    def test_a_failure_inside_leaves_the_reply(self):
        broken = SimpleNamespace(choices=None)
        self.assertIs(self.guard().turn(request=TOOLS, next_call=lambda r: broken, session_id="s1"), broken)

    def test_it_wraps_the_model_last(self):
        # Middleware runs in the order registered, the last nearest the model: a reminder answered
        # with no model (remind.py) never reaches it, and it sees the provider's own answer.
        source = Path(plugin.__file__).read_text(encoding="utf-8")
        registered = re.findall(r'register_middleware\("llm_execution", (\w+)\.', source)
        self.assertEqual(registered, ["remind", "silence", "planonly"])


if __name__ == "__main__":
    unittest.main()
