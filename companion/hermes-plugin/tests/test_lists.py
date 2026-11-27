"""The person's lists (`lists.py`): python -m unittest discover -s companion/hermes-plugin/tests"""
import base64
import json
import tempfile
import unittest
from pathlib import Path

from test_routines import plugin

lists = plugin.lists


def do(home, **args):
    return lists.change(home, args, by="default", now=1_000)


class ListsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_make_add_check_and_show(self):
        made = do(self.home, action="make", title="Groceries", items=["Milk", "Eggs"])
        self.assertIn("made", made)
        self.assertEqual(made["items"], ["1. [ ] Milk", "2. [ ] Eggs"])
        do(self.home, action="add", list="groceries", items=["Bread"])
        checked = do(self.home, action="check", list="Groceries", items=["2", "bread"])
        self.assertEqual(checked["checked"], ["Eggs", "Bread"])
        self.assertEqual(checked["open"], 1)
        self.assertEqual(checked["done"], 2)
        shown = do(self.home, action="show")
        self.assertEqual(shown["lists"][0]["items"], ["1. [ ] Milk", "2. [x] Eggs", "3. [x] Bread"])

    def test_an_item_gets_new_words(self):
        """2026-11-24: "Allow to edit the todo items with a long press"."""
        do(self.home, action="make", title="To Do", items=["Dispute Hyat charge", "Stretch"])
        edited = do(self.home, action="edit", list="To Do", items=["1"], title="  Dispute the Hyatt charge ")
        self.assertEqual((edited["edited"], edited["now"]), ("Dispute Hyat charge", "Dispute the Hyatt charge"))
        self.assertEqual(edited["items"][0], "1. [ ] Dispute the Hyatt charge")
        item = lists.load(self.home)[0]["items"][0]
        self.assertFalse(item["done"])
        self.assertIn("error", do(self.home, action="edit", list="To Do", items=["Nothing like it"], title="x"))
        self.assertIn("error", do(self.home, action="edit", list="To Do", items=["2"], title="  "))
        self.assertEqual(lists.load(self.home)[0]["items"][1]["text"], "Stretch")

    def test_one_list_needs_no_name_and_two_do(self):
        do(self.home, action="make", title="To Do")
        self.assertEqual(do(self.home, action="add", items=["Call the vet"])["added"], 1)
        do(self.home, action="make", title="Packing")
        missed = do(self.home, action="add", items=["Socks"])
        self.assertIn("error", missed)
        self.assertEqual(missed["lists"], ["To Do", "Packing"])

    def test_making_a_list_twice_keeps_one(self):
        do(self.home, action="make", title="Groceries", items=["Milk"])
        again = do(self.home, action="make", title="groceries", items=["Eggs"])
        self.assertIn("already_there", again)
        self.assertEqual(len(lists.load(self.home)), 1)
        self.assertEqual(again["items"], ["1. [ ] Milk", "2. [ ] Eggs"])

    def test_uncheck_remove_clear_rename_delete(self):
        do(self.home, action="make", title="Chores", items=["Dishes", "Laundry", "Trash"])
        do(self.home, action="check", list="Chores", items=["1", "3"])
        self.assertEqual(do(self.home, action="uncheck", list="Chores", items=["Trash"])["unchecked"], ["Trash"])
        self.assertEqual(do(self.home, action="remove", list="Chores", items=["laundry"])["removed"], ["Laundry"])
        self.assertEqual(do(self.home, action="clear_done", list="Chores")["cleared"], 1)
        self.assertEqual(do(self.home, action="rename", list="Chores", title="House")["items"], ["1. [ ] Trash"])
        self.assertEqual(do(self.home, action="delete", list="House")["deleted"], "House")
        self.assertEqual(lists.load(self.home), [])

    def test_unknown_items_and_actions_are_said(self):
        do(self.home, action="make", title="To Do", items=["A thing"])
        self.assertIn("error", do(self.home, action="check", list="To Do", items=["9"]))
        partly = do(self.home, action="check", list="To Do", items=["1", "nothing like it"])
        self.assertEqual(partly["not_found"], ["nothing like it"])
        self.assertIn("error", do(self.home, action="fly"))
        self.assertIn("error", do(self.home, action="make", title="  "))

    def test_items_are_trimmed_and_capped(self):
        do(self.home, action="make", title="x" * 100, items=["  lots   of   space  ", "", "y" * 500])
        kept = lists.load(self.home)[0]
        self.assertEqual(len(kept["title"]), lists.TITLE)
        self.assertEqual([i["text"] for i in kept["items"]][0], "lots of space")
        self.assertEqual(len(kept["items"]), 2)
        self.assertEqual(len(kept["items"][1]["text"]), lists.TEXT)

    def test_a_to_do_gets_a_help_line(self):
        """1.46.0 (2026-11-25, the Agent Can Help layout): what the agent could do for a to-do, shown
        under it in Redde; taken off with '' or by new words."""
        do(self.home, action="make", title="House To-Dos", items=["Call the dentist", "Fix the bike"])
        said = do(self.home, action="help", list="House To-Dos", items=["1"], help="  Find their number and hours ")
        self.assertEqual((said["help"], said["for"]), ("Find their number and hours", ["Call the dentist"]))
        self.assertEqual(said["items"][0], "1. [ ] Call the dentist (you could: Find their number and hours)")
        listed = lists.listing(self.home)[0]["items"]
        self.assertEqual(listed[0]["help"], "Find their number and hours")
        self.assertNotIn("help", listed[1])
        self.assertLessEqual(len(do(self.home, action="help", list="House To-Dos", items=["2"], help="x" * 200)["help"]), lists.HELP)
        do(self.home, action="help", list="House To-Dos", items=["2"], help="")
        self.assertNotIn("help", lists.listing(self.home)[0]["items"][1])
        do(self.home, action="edit", list="House To-Dos", items=["1"], title="Call the vet")
        self.assertNotIn("help", lists.listing(self.home)[0]["items"][0])
        self.assertIn("error", do(self.home, action="help", list="House To-Dos", items=["Nothing like it"], help="Hm"))
        listed = json.loads(lists.slash(self.home, ["list"]).removeprefix("redde-push lists "))
        self.assertEqual(listed["can"], ["help"], "the app hears it can offer help lines")

    def test_the_apps_command(self):
        listed = lists.slash(self.home, ["list"])
        self.assertTrue(listed.startswith("redde-push lists "))
        self.assertEqual(json.loads(listed.removeprefix("redde-push lists "))["lists"], [])
        do(self.home, action="make", title="Groceries", items=["Milk"])
        item = lists.listing(self.home)[0]["items"][0]
        change = base64.urlsafe_b64encode(json.dumps({"action": "check", "list": lists.listing(self.home)[0]["id"],
                                                       "items": [item["id"]]}).encode()).decode().rstrip("=")
        said = json.loads(lists.slash(self.home, ["do", change]).removeprefix("redde-push lists "))
        self.assertEqual(said["said"]["checked"], ["Milk"])
        self.assertTrue(said["lists"][0]["items"][0]["done"])
        self.assertIn("for the Redde app", lists.slash(self.home, ["do", "not base64!"]))
        self.assertIn("for the Redde app", lists.slash(self.home, ["eat"]))

    def test_an_item_whose_id_is_all_digits_is_found_by_it(self):
        do(self.home, action="make", title="Groceries", items=["Milk", "Eggs"])
        kept = lists.load(self.home)
        kept[0]["items"][1]["id"] = "40417253"
        lists.save(self.home, kept)
        said = do(self.home, action="check", list="Groceries", items=["40417253"])
        self.assertEqual(said["checked"], ["Eggs"])
        self.assertFalse(any(lists._item_id().isdigit() for _ in range(2000)))

    def test_the_turn_note(self):
        for said in ("Make me a to-do list", "add milk to my grocery list", "check off the eggs", "what's on my lists?",
                     "put batteries on the shopping list", "Start a packing list for Maine"):
            self.assertIsNotNone(lists.turn_note(said), said)
        for said in ("remind me to call mom", "what's the weather", "I listened to it"):
            self.assertIsNone(lists.turn_note(said), said)
        self.assertIsNone(lists.turn_note("make a to-do list", platform="cron"))

    def test_every_bot_shares_the_main_homes_lists(self):
        calls = []

        class Ctx:
            def register_tool(self, **kw):
                calls.append(kw)

        bot = self.home / "profiles" / "scout"
        bot.mkdir(parents=True)
        lists.register(Ctx(), lambda: bot)
        handle = calls[0]["handler"]
        json.loads(handle({"action": "make", "title": "To Do", "items": ["Fix the gate"]}))
        self.assertEqual(lists.load(self.home)[0]["by"], "scout")
        self.assertFalse(lists.path(bot).exists())



class ListLooksTests(unittest.TestCase):
    """1.37.0 (2026-11-23, of Christmas films: "make these lists a bit more fun")."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.asked, self.again = [], []
        self.real = lists.FIND_AGAIN, lists.KEYED
        lists.BACKGROUND, lists.FIND, lists.KEYED = False, self.find, lambda: False

    def tearDown(self):
        lists.BACKGROUND, lists.FIND = True, lambda title, year, deadline: plugin.posters.lookup(title, year, None, deadline)
        lists.FIND_AGAIN, lists.KEYED = self.real
        self.tmp.cleanup()

    def find(self, title, year, deadline):
        self.asked.append((title, year))
        return None if title == "A Very Brady Christmas" else f"https://upload.wikimedia.org/{title.replace(' ', '_')}.jpg"

    def test_a_look_is_guessed_from_the_title(self):
        self.assertEqual(lists.guess("Christmas Movies"), ("watch", "🎄", "red"))
        self.assertEqual(lists.guess("Groceries"), ("shopping", "🛒", "green"))
        self.assertEqual(lists.guess("To Do"), ("todo", "✅", "blue"))
        self.assertEqual(lists.guess("Ready for Monday"), ("other", "📝", "blue"), "not 'reading'")
        self.assertEqual(lists.guess("Books for the beach"), ("reading", "🏖️", "teal"))

    def test_the_agent_gives_a_look_or_changes_it(self):
        made = do(self.home, action="make", title="Saturday", kind="todo", emoji="🧹", color="mint")
        self.assertEqual((made["kind"], made["emoji"], made["color"]), ("todo", "🧹", "mint"))
        made = do(self.home, action="make", title="Gifts", emoji="hello", color="plaid")
        self.assertEqual((made["emoji"], made["color"]), ("🎁", "red"))
        self.assertEqual(len(made["not_kept"]), 2)
        styled = do(self.home, action="style", list="Saturday", kind="shopping")
        self.assertEqual(styled["styled"]["kind"], "shopping")
        self.assertIn("error", do(self.home, action="style", list="Saturday"))
        self.assertIn("error", do(self.home, action="style", list="Saturday", color="plaid"))
        self.assertEqual(lists.look({"title": "Errands", "kind": "watch"})["emoji"], "🍿", "a kind given brings its own look")

    def test_a_watch_lists_titles_get_posters_and_years(self):
        do(self.home, action="make", title="Christmas Movies",
           items=["Home Alone (1990)", "It's a Wonderful Life", "A Very Brady Christmas"])
        self.assertEqual(sorted(self.asked), [("A Very Brady Christmas", None), ("Home Alone", "1990"), ("It's a Wonderful Life", None)])
        listed = lists.listing(self.home)[0]
        self.assertEqual((listed["kind"], listed["emoji"], listed["color"]), ("watch", "🎄", "red"))
        home_alone, wonderful, brady = listed["items"]
        self.assertEqual((home_alone["poster"], home_alone["year"]), ("https://upload.wikimedia.org/Home_Alone.jpg", 1990))
        self.assertEqual(home_alone["text"], "Home Alone (1990)", "the text as they wrote it")
        self.assertNotIn("poster", brady)
        self.assertEqual(len(self.asked), 3, "each title tried once, not at every look")
        do(self.home, action="add", list="Christmas Movies", items=["Elf"])
        self.assertEqual(self.asked[-1], ("Elf", None))

    def test_a_title_with_no_poster_is_looked_for_again_later_a_few_times(self):
        # 1.42.1: a new film's page may have none yet; before, a miss was never tried again.
        at = 1_795_000_000
        lists.save(self.home, [{"id": "w", "title": "Christmas Movies", "kind": "watch",
                                "items": [{"id": "b", "text": "A Very Brady Christmas", "done": False}]}])
        lists.fill_posters(self.home, now=at)
        lists.fill_posters(self.home, now=at + 3600)
        self.assertEqual(len(self.asked), 1, "not at every look")
        for n in range(1, lists.POSTER_TRIES + 2):
            lists.fill_posters(self.home, now=at + n * lists.POSTER_RETRY)
        self.assertEqual(len(self.asked), lists.POSTER_TRIES, "so many times in all")
        self.assertNotIn("poster_misses", lists.listing(self.home)[0]["items"][0], "for the plugin, not the phone")

    def test_one_missed_by_an_older_search_is_looked_for_at_once(self):
        lists.save(self.home, [{"id": "w", "title": "Christmas Movies", "kind": "watch",
                                "items": [{"id": "p", "text": "The polar express", "done": False, "poster_tried": 1_700_000_000}]}])
        listed = lists.listing(self.home)
        self.assertEqual(self.asked, [("The polar express", None)])
        self.assertEqual(lists.listing(self.home)[0]["items"][0]["poster"], "https://upload.wikimedia.org/The_polar_express.jpg")
        self.assertNotIn("poster", listed[0]["items"][0], "the first look answers before the poster is in")

    def test_old_posters_are_looked_for_on_tmdb_once_a_key_is_there(self):
        # 1.44.0, 2026-11-24: "refetch the old posters too".
        tmdb = plugin.posters.TMDB_IMAGES
        lists.save(self.home, [{"id": "w", "title": "Christmas Movies", "kind": "watch", "items": [
            {"id": "e", "text": "Elf (2003)", "done": False, "poster": "https://upload.wikimedia.org/Elf.jpg", "poster_tried": 1},
            {"id": "b", "text": "A Very Brady Christmas", "done": False, "poster": "https://upload.wikimedia.org/Brady.jpg", "poster_tried": 1},
            {"id": "h", "text": "Home Alone", "done": False, "poster": tmdb + "/home.jpg", "poster_tried": 1},
            {"id": "x", "text": "Lost Film", "done": False, "poster_tried": 1, "poster_misses": lists.POSTER_TRIES}]}])

        def again(title, year, deadline, series):
            self.again.append((title, year))
            self.assertIs(series, None if title == "Home Alone" else False, "a poster from Wikipedia is a film's")
            return None if title == "A Very Brady Christmas" else f"{tmdb}/{title.replace(' ', '_')}.jpg"
        lists.FIND_AGAIN = again
        lists.fill_posters(self.home)
        self.assertEqual(self.again, [], "no key, nothing asked again")

        lists.KEYED = lambda: True
        lists.fill_posters(self.home)
        self.assertEqual(sorted(self.again), [("A Very Brady Christmas", None), ("Elf", "2003"), ("Home Alone", None)],
                         "the missed isn't asked; TMDb's own only for its plot (1.52.0)")
        self.assertEqual(self.asked, [], "and only TMDb is")
        elf, brady, home_alone, lost = lists.listing(self.home)[0]["items"]
        self.assertEqual(elf["poster"], tmdb + "/Elf.jpg")
        self.assertEqual(brady["poster"], "https://upload.wikimedia.org/Brady.jpg", "kept when TMDb has none")
        self.assertEqual(home_alone["poster"], tmdb + "/Home_Alone.jpg", "looked at for its plot: poster and plot from the one look")
        self.assertNotIn("poster_again", elf, "for the plugin, not the phone")
        lists.fill_posters(self.home)
        self.assertEqual(len(self.again), 3, "once")

    def test_a_film_keeps_what_its_about_and_its_page(self):
        # 1.52.0, 2026-11-26: "under the poster art, add a little plot description"; TMDb's page for the long press.
        tmdb = plugin.posters.TMDB_IMAGES
        found = plugin.posters.Found.at(tmdb + "/elf.jpg", "https://www.themoviedb.org/movie/10719",
                                        "Buddy, raised by elves at the North Pole, goes to New York to find his father.")
        lists.FIND = lambda title, year, deadline: found if title == "Elf" else None
        do(self.home, action="make", title="Christmas Movies", items=["Elf", "Klaus"])
        elf, klaus = lists.listing(self.home)[0]["items"]
        self.assertEqual(elf["plot"], found.plot)
        self.assertEqual(elf["page"], "https://www.themoviedb.org/movie/10719")
        self.assertNotIn("plot", klaus)
        # Renamed: looked up again, the old plot gone with the old poster.
        lists.FIND = lambda title, year, deadline: None
        do(self.home, action="edit", list="Christmas Movies", items=["Elf"], title="Elf (2003 film)")
        self.assertNotIn("plot", lists.listing(self.home)[0]["items"][0])

    def test_a_tmdb_poster_from_before_gets_its_plot_once(self):
        tmdb = plugin.posters.TMDB_IMAGES
        lists.save(self.home, [{"id": "w", "title": "Christmas Movies", "kind": "watch", "items": [
            {"id": "h", "text": "Home Alone", "done": False, "poster": tmdb + "/home.jpg", "poster_tried": 1, "poster_again": 2}]}])
        asked = []

        def again(title, year, deadline, series):
            asked.append(title)
            return plugin.posters.Found.at(tmdb + "/home.jpg", "https://www.themoviedb.org/movie/771",
                                           "Eight-year-old Kevin is accidentally left behind when his family flies to Paris.")
        lists.FIND_AGAIN, lists.KEYED = again, (lambda: False)
        lists.fill_posters(self.home)
        self.assertEqual(asked, [], "no key: TMDb can't be asked")
        lists.KEYED = lambda: True
        lists.fill_posters(self.home)
        lists.fill_posters(self.home)
        self.assertEqual(asked, ["Home Alone"], "once")
        home = lists.listing(self.home)[0]["items"][0]
        self.assertTrue(home["plot"].startswith("Eight-year-old Kevin"))
        self.assertEqual((home["poster"], home["page"]), (tmdb + "/home.jpg", "https://www.themoviedb.org/movie/771"))

    def test_posters_the_first_tmdb_look_took_are_looked_at_again(self):
        # Its first round took TMDb's most watched this week: Home Alone got a Korean show's.
        tmdb = plugin.posters.TMDB_IMAGES
        lists.save(self.home, [{"id": "w", "title": "Christmas Movies", "kind": "watch", "items": [
            {"id": "h", "text": "Home Alone", "done": False, "poster": tmdb + "/show.jpg", "poster_tried": 1, "poster_tmdb": 2},
            {"id": "s", "text": "Severance", "done": False, "poster": "https://static.tvmaze.com/s.jpg", "poster_tried": 1}]}])
        asked = {}

        def again(title, year, deadline, series):
            asked[title] = series
            return f"{tmdb}/{title.replace(' ', '_')}.jpg"
        lists.FIND_AGAIN, lists.KEYED = again, (lambda: True)
        lists.fill_posters(self.home)
        self.assertEqual(asked, {"Home Alone": None, "Severance": True}, "TVmaze's is a series'")
        home_alone, _ = lists.load(self.home)[0]["items"]
        self.assertEqual(home_alone["poster"], tmdb + "/Home_Alone.jpg")
        self.assertNotIn("poster_tmdb", home_alone)
        asked.clear()
        lists.fill_posters(self.home)
        self.assertEqual(asked, {}, "once")

    def test_a_film_edited_has_its_poster_looked_for_again(self):
        do(self.home, action="make", title="Christmas Movies", items=["Home Alone 2"])
        self.assertIn("poster", lists.load(self.home)[0]["items"][0])
        do(self.home, action="edit", list="Christmas Movies", items=["1"], title="Elf (2003)")
        self.assertEqual(self.asked[-1], ("Elf", "2003"))
        item = lists.listing(self.home)[0]["items"][0]
        self.assertEqual((item["text"], item["poster"], item["year"]), ("Elf (2003)", "https://upload.wikimedia.org/Elf.jpg", 2003))

    def test_other_lists_look_nothing_up(self):
        do(self.home, action="make", title="Groceries", items=["Milk"])
        lists.listing(self.home)
        self.assertEqual(self.asked, [])

    def test_an_older_list_gets_its_look_and_posters_on_the_next_look(self):
        lists.save(self.home, [{"id": "old1", "title": "Christmas Movies", "items": [{"id": "a", "text": "Die Hard", "done": False}]}])
        lists.listing(self.home)
        self.assertEqual(lists.listing(self.home)[0]["items"][0]["poster"], "https://upload.wikimedia.org/Die_Hard.jpg")

    def test_the_tool_offers_the_look(self):
        class Ctx:
            def register_tool(self, **made):
                self.made = made
        ctx = Ctx()
        lists.register(ctx, lambda: self.home)
        props = ctx.made["schema"]["parameters"]["properties"]
        self.assertEqual(props["kind"]["enum"], list(lists.KINDS))
        self.assertIn("style", props["action"]["enum"])
        self.assertLess(len(json.dumps(ctx.made["schema"])), 2000)



class PlanTests(unittest.TestCase):
    """1.38.0 (2026-11-23): "Donnie Brasco, Thanksgiving night, with Robin" kept where something
    looks at it: a card on the day, and a check after that it happened."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.jobs, self.removed = [], []
        lists.BACKGROUND, lists.FIND = False, lambda title, year, deadline: None
        lists.MAKE_JOB = lambda prompt, schedule, name=None, deliver=None: (self.jobs.append((prompt, schedule, name)) or {"id": f"j{len(self.jobs)}"})
        lists.REMOVE_JOB = self.removed.append
        self.now = 1_795_000_000   # 2026-11-18

    def tearDown(self):
        lists.BACKGROUND, lists.MAKE_JOB, lists.REMOVE_JOB = True, None, None
        lists.FIND = lambda title, year, deadline: plugin.posters.lookup(title, year, None, deadline)
        self.tmp.cleanup()

    def plan(self, **args):
        return lists.change(self.home, {"action": "plan", "list": "Movies", **args}, by="default", now=self.now)

    def test_a_planned_film_is_reminded_on_the_day_and_checked_the_morning_after(self):
        lists.change(self.home, {"action": "make", "title": "Movies", "items": ["Elf"]}, now=self.now)
        said = self.plan(items=["Donnie Brasco"], when="2026-11-26T19:30:00-05:00", **{"with": "Robin"})
        self.assertEqual(said["planned"], "Donnie Brasco")
        self.assertIn("calendar", said["said"])
        (remind, at1, name1), (check, at2, _) = self.jobs
        self.assertEqual(at1, "2026-11-26T10:00-05:00")
        self.assertEqual(at2, "2026-11-27T10:00-05:00", "an evening plan: checked the next morning")
        self.assertTrue(name1.startswith("[redde-plan:"))
        self.assertIn("7:30 PM: Donnie Brasco with Robin", remind)
        self.assertIn("Get Donnie Brasco ready to play", remind)
        self.assertIn("shows it played", check)
        self.assertIn("@mention", check)
        self.assertIn("Did you watch Donnie Brasco?", check)
        self.assertIn("find another night with Robin", check)
        item = lists.listing(self.home)[0]["items"][1]
        self.assertEqual((item["when"], item["with"]), ("2026-11-26T19:30-05:00", "Robin"))
        self.assertIn(item["id"], check, "the check ticks off this item")
        self.assertIn("(planned 2026-11-26T19:30-05:00 with Robin)", said["items"][1])

    def test_with_the_phone_putting_nights_on_its_calendar_the_agent_leaves_it(self):
        # 1.50.0 (2026-11-26): "When a movie on list is given a time and date, have it added to the calendar".
        lists.change(self.home, {"action": "make", "title": "Movies", "items": ["Elf"]}, now=self.now)
        lists.change(self.home, {"action": "make", "title": "Chores", "items": ["Gutters"], "kind": "todo"}, now=self.now)
        said = self.plan(items=["Elf"], when="2026-11-26T19:30:00-05:00")
        self.assertIn("put it there with your calendar tool", said["said"], "no phone has said so: the agent's job")
        lists.nights(self.home, True, at=self.now)
        self.assertTrue(lists.calendar_by_app(self.home, self.now))
        self.jobs.clear()
        said = self.plan(items=["Elf"], when="2026-11-27T20:00:00-05:00", **{"with": "Robin"})
        self.assertIn("Redde puts it on their calendar itself", said["said"])
        self.assertIn("don't add it with a calendar tool", said["said"])
        check = self.jobs[-1][0]
        self.assertIn("find another night with Robin and plan it on my list", check)
        self.assertNotIn("put it on my calendar", check)
        chore = lists.change(self.home, {"action": "plan", "list": "Chores", "items": ["Gutters"],
                                         "when": "2026-11-28T10:00:00-05:00"}, by="default", now=self.now)
        self.assertIn("put it there with your calendar tool", chore["said"], "only a watch list's nights")
        added = lists.change(self.home, {"action": "add", "list": "Movies", "items": ["Klaus"],
                                         "when": "2026-11-29T19:00:00-05:00"}, by="default", now=self.now)
        self.assertIn("Redde puts it on their calendar itself", added["said"], "a film added with its night too")
        # The phone's word lasts two weeks, and goes with `off`.
        self.assertFalse(lists.calendar_by_app(self.home, self.now + lists.NIGHTS_FOR + 1))
        lists.nights(self.home, False)
        self.assertFalse(lists.calendar_by_app(self.home, self.now))
        self.assertFalse(lists.calendar_by_app(None))

    def test_the_phone_says_it_puts_the_nights_on_its_calendar(self):
        self.assertIn('"nights": true', lists.slash(self.home, ["nights", "on"]))
        self.assertTrue(lists.calendar_by_app(self.home))
        self.assertIn('"nights": false', lists.slash(self.home, ["nights", "off"]))
        self.assertFalse(lists.calendar_by_app(self.home))
        self.assertFalse((self.home / "redde-push" / lists.NIGHTS).exists())
        self.assertIn("for the Redde app", lists.slash(self.home, ["nights", "maybe"]))
        (self.home / "redde-push" / lists.NIGHTS).write_text("not json")
        self.assertFalse(lists.calendar_by_app(self.home))

    def test_one_device_at_a_time_keeps_the_calendar(self):
        # 1.51.0: an iPhone and an iPad opened together each put every film on the calendar.
        now = self.now
        self.assertTrue(lists.nights(self.home, True, at=now, device="phone")["mine"])
        self.assertEqual(lists.nights(self.home, True, at=now + 5, device="pad"), {"nights": True, "by": "phone", "mine": False})
        self.assertTrue(lists.nights(self.home, True, at=now + 86400, device="phone")["mine"], "the one asks again")
        self.assertFalse(lists.nights(self.home, True, at=now + 86400 + 60, device="pad")["mine"])
        self.assertTrue(lists.calendar_by_app(self.home, now + 86400))
        # Off from the other device leaves it with the one; off from the one frees it.
        self.assertEqual(lists.nights(self.home, False, at=now + 86400 + 90, device="pad")["mine"], False)
        self.assertTrue(lists.calendar_by_app(self.home, now + 86400))
        self.assertEqual(lists.nights(self.home, False, at=now + 86400 + 120, device="phone"), {"nights": False})
        self.assertTrue(lists.nights(self.home, True, at=now + 86400 + 150, device="pad")["mine"])
        # Not asked again for three days: whichever asks next.
        later = now + 86400 + 150 + lists.NIGHTS_LEASE + 1
        self.assertTrue(lists.nights(self.home, True, at=later, device="phone")["mine"])
        # Over the command (the clock's own time), the device's name kept to letters, digits and dashes.
        lists.nights(self.home, False)
        said = json.loads(lists.slash(self.home, ["nights", "on", "pad;rm -rf"]).removeprefix("redde-push lists "))
        self.assertEqual((said["by"], said["mine"]), ("padrm-rf", True))
        self.assertIn('"mine": false', lists.slash(self.home, ["nights", "on", "phone"]))

    def test_planning_again_drops_the_old_jobs(self):
        lists.change(self.home, {"action": "make", "title": "Movies", "items": ["Elf"]}, now=self.now)
        self.plan(items=["1"], when="2026-11-26T19:30:00-05:00")
        self.plan(items=["Elf"], when="2026-11-27T20:00:00-05:00")
        self.assertEqual(self.removed, ["j1", "j2"])
        self.assertEqual(len(lists.load(self.home)[0]["items"]), 1)

    def test_unplan_takes_the_date_and_its_jobs_off(self):
        lists.change(self.home, {"action": "make", "title": "Movies", "items": ["Elf"]}, now=self.now)
        self.plan(items=["Elf"], when="2026-11-26T19:30:00-05:00", **{"with": "Robin"})
        said = lists.change(self.home, {"action": "unplan", "list": "Movies", "items": ["1"]}, by="default", now=self.now)
        self.assertEqual(said["unplanned"], "Elf")
        self.assertEqual(self.removed, ["j1", "j2"])
        item = lists.load(self.home)[0]["items"][0]
        for field in ("when", "with", "plan_jobs"):
            self.assertNotIn(field, item)
        self.assertNotIn("planned", said["items"][0])

    def test_unplan_needs_one_item_it_can_find(self):
        lists.change(self.home, {"action": "make", "title": "Movies", "items": ["Elf"]}, now=self.now)
        said = lists.change(self.home, {"action": "unplan", "list": "Movies", "items": ["Nothing like it"]}, by="default", now=self.now)
        self.assertIn("error", said)

    def test_a_morning_plan_and_one_already_under_way(self):
        lists.change(self.home, {"action": "make", "title": "To Do", "items": ["Call the vet"]}, now=self.now)
        lists.change(self.home, {"action": "plan", "list": "To Do", "items": ["1"], "when": "2026-11-19T09:00:00-05:00"}, now=self.now)
        (remind, at1, _), (check, at2, _) = self.jobs
        self.assertEqual((at1, at2), ("2026-11-19T07:00-05:00", "2026-11-19T12:00-05:00"))
        self.assertIn("Did Call the vet happen?", check)
        self.assertIn("calendar, mail", check)

    def test_an_item_added_with_its_date_goes_under_that_day(self):
        """2026-11-24: "Black Friday subscription sale starts 11/26 7PM EST" went on To Do with its date
        only in its words, so it sat undated at the top instead of under Wednesday."""
        lists.change(self.home, {"action": "make", "title": "To Do", "items": ["Stretch"]}, now=self.now)
        said = lists.change(self.home, {"action": "add", "list": "To Do", "items": ["Black Friday sale starts"],
                                        "when": "2026-11-26T19:00:00-05:00"}, by="default", now=self.now)
        self.assertEqual((said["added"], said["planned"], said["when"]), (1, ["Black Friday sale starts"], "2026-11-26T19:00-05:00"))
        self.assertIn("reminds them on the day", said["said"])
        stretch, sale = lists.load(self.home)[0]["items"]
        self.assertNotIn("when", stretch)
        self.assertEqual((sale["when"], sale["plan_jobs"]), ("2026-11-26T19:00-05:00", ["j1", "j2"]))
        self.assertEqual([at for _, at, _ in self.jobs], ["2026-11-26T10:00-05:00", "2026-11-27T10:00-05:00"])
        self.assertIn("(planned 2026-11-26T19:00-05:00)", said["items"][1])

    def test_a_date_only_in_the_words_is_said_back(self):
        lists.change(self.home, {"action": "make", "title": "To Do"}, now=self.now)
        sale = "Black Friday subscription sale starts 11/26 7PM EST (runs to 11/29 7PM EST)"
        said = lists.change(self.home, {"action": "add", "list": "To Do", "items": [
            sale, "Rest the apple wine batch (5 gal, EC-1118)", "Check business Apple application"]}, now=self.now)
        self.assertEqual(said["no_date"], [sale])
        self.assertIn("'plan'", said["said"])
        self.assertEqual(self.jobs, [], "nothing dated on a guess")
        for plain in ("Stretch", "Support 24/7", "Decide 3 things", "Market 5 items"):
            self.assertNotIn("no_date", lists.change(self.home, {"action": "add", "list": "To Do", "items": [plain]}, now=self.now), plain)
        for dated in ("Dentist Dec 3rd", "Pay rent 1 March", "Call mom Friday", "Meeting at 10:30am", "Bins out tomorrow"):
            self.assertIn("no_date", lists.change(self.home, {"action": "add", "list": "To Do", "items": [dated]}, now=self.now), dated)

    def test_adding_with_a_wrong_date_adds_nothing(self):
        lists.change(self.home, {"action": "make", "title": "To Do"}, now=self.now)
        said = lists.change(self.home, {"action": "add", "list": "To Do", "items": ["Sale"], "when": "2026-11-26T19:00"}, now=self.now)
        self.assertIn("UTC offset", said["error"])
        self.assertEqual(lists.load(self.home)[0]["items"], [])

    def test_a_dated_item_edited_is_reminded_by_its_new_words(self):
        lists.change(self.home, {"action": "make", "title": "Movies", "items": ["Elf"]}, now=self.now)
        self.plan(items=["Elf"], when="2026-11-26T19:30:00-05:00", **{"with": "Robin"})
        lists.change(self.home, {"action": "edit", "list": "Movies", "items": ["1"], "title": "Elf (2003)"}, now=self.now)
        self.assertEqual(self.removed, ["j1", "j2"])
        item = lists.load(self.home)[0]["items"][0]
        self.assertEqual((item["when"], item["with"], item["plan_jobs"]), ("2026-11-26T19:30-05:00", "Robin", ["j3", "j4"]))
        self.assertIn("7:30 PM: Elf (2003) with Robin", self.jobs[2][0])

    def test_what_wont_do(self):
        lists.change(self.home, {"action": "make", "title": "Movies"}, now=self.now)
        self.assertIn("UTC offset", self.plan(items=["Elf"], when="2026-11-26T19:30")["error"])
        self.assertIn("60 days", self.plan(items=["Elf"], when="2027-06-01T19:30:00-05:00")["error"])
        self.assertIn("one item", self.plan(items=["Elf", "Heat"], when="2026-11-26T19:30:00-05:00")["error"])

    def test_a_plan_in_a_message_is_noted(self):
        self.assertIn("'plan'", lists.turn_note("We're going to watch Donnie Brasco on Thanksgiving with Robin"))
        self.assertIn("'plan'", lists.turn_note("let's see Wicked friday night"))
        self.assertIsNone(lists.turn_note("I watched a film"))

    def test_a_film_planned_comes_with_its_card(self):
        said = lists.turn_note("I’m going to watch behind the candelabra the day after Thanksgiving")
        self.assertIn("'plan'", said)
        self.assertIn(lists.SHOW_NOTE, said)
        self.assertIn(lists.SHOW_NOTE, lists.turn_note("let's see Wicked friday night"))
        self.assertNotIn(lists.SHOW_NOTE, lists.turn_note("We're going to cook lasagna on Sunday night"))
        self.assertNotIn(lists.SHOW_NOTE, lists.turn_note("make a to-do list"))


if __name__ == "__main__":
    unittest.main()
