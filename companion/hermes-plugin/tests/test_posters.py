"""python -m unittest discover -s companion/hermes-plugin/tests

A show card's posters, checked and found on the server (1.36.2, 2026-11-22: Sol built a TMDb
address for Donnie Brasco's poster from the film's id, and the card showed no poster)."""
import json
import time
import unittest
from urllib.parse import quote

from test_calls import plugin

posters, cards = plugin.posters, plugin.cards

WIKI = "https://en.wikipedia.org/api/rest_v1/page/summary/"
POSTER = "https://upload.wikimedia.org/wikipedia/en/2/2b/Donnie_Brasco.jpg"


class Web:
    """What each address answers: (how, status, content type, body)."""
    def __init__(self, pages):
        self.pages, self.asked = pages, []

    def __call__(self, url, deadline):
        self.asked.append(url)
        how, status, kind, body = self.pages.get(url, ("ok", 404, "text/html", b""))
        return how, status, {"content-type": kind}, body


def summary(description, image=POSTER):
    return ("ok", 200, "application/json", json.dumps({"type": "standard", "description": description,
                                                       "originalimage": {"source": image}}).encode())


class PosterTests(unittest.TestCase):
    def setUp(self):
        self.real, self.key = posters.GET, posters.KEY
        posters.KEY = lambda: None   # (no TMDb key, whatever this computer has)

    def tearDown(self):
        posters.GET, posters.KEY = self.real, self.key

    def show(self, **item):
        return {"type": "show", "title": "Thursday", "items": [{"title": "Donnie Brasco", "year": 1997, "format": "movie", **item}]}

    def test_a_poster_that_loads_stays(self):
        posters.GET = Web({"https://image.example/p.jpg": ("ok", 200, "image/jpeg", b"")})
        filled = posters.fill(self.show(poster="https://image.example/p.jpg"))
        self.assertEqual(filled["items"][0]["poster"], "https://image.example/p.jpg")

    def test_a_made_up_poster_is_found_on_wikipedia_instead(self):
        posters.GET = web = Web({WIKI + "Donnie_Brasco_(1997_film)": summary("1997 film by Mike Newell")})
        filled = posters.fill(self.show(poster="https://image.tmdb.org/t/p/w500/9366.jpg"))
        self.assertEqual(filled["items"][0]["poster"], POSTER)
        self.assertEqual(web.asked[0], "https://image.tmdb.org/t/p/w500/9366.jpg", "its own poster tried first")

    def test_the_page_it_was_found_on_is_what_the_title_opens(self):
        # 2026-11-23: "make the movie card clickable": a card with no link gets the poster's page.
        page = "https://en.m.wikipedia.org/wiki/Donnie_Brasco_(film)"
        found = json.loads(summary("1997 film by Mike Newell")[3])
        found["content_urls"] = {"mobile": {"page": page}}
        posters.GET = Web({WIKI + "Donnie_Brasco_(1997_film)": ("ok", 200, "application/json", json.dumps(found).encode())})
        item = posters.fill(self.show(title="Donnie Brasco (1997)", year=None, format=None))["items"][0]
        self.assertEqual((item["poster"], item["url"]), (POSTER, page))
        self.assertIs(type(item["poster"]), str, "plain text in the card")
        kept = posters.fill(self.show(url="https://www.imdb.com/title/tt0119008/"))["items"][0]
        self.assertEqual(kept["url"], "https://www.imdb.com/title/tt0119008/", "the agent's own link stays")

    def test_a_missing_poster_is_found_and_a_bare_title_must_be_the_film(self):
        posters.GET = Web({WIKI + "Donnie_Brasco": summary("American FBI agent")})
        self.assertNotIn("poster", posters.fill(self.show())["items"][0], "the man's page isn't the film's")
        series = json.dumps([{"show": {"name": "Severance (Korea)", "premiered": "2019-01-01", "image": {"original": "https://x.example/k.jpg"}}},
                             {"show": {"name": "Severance", "premiered": "2022-02-18",
                                       "image": {"original": "https://static.tvmaze.com/s.jpg"}}}]).encode()
        posters.GET = Web({"https://api.tvmaze.com/search/shows?q=Severance": ("ok", 200, "application/json", series)})
        filled = posters.fill({"type": "show", "items": [{"title": "Severance", "year": "2022-", "format": "series"}]})
        self.assertEqual(filled["items"][0]["poster"], "https://static.tvmaze.com/s.jpg", "a series' from TVmaze, its name and year matched")

    def test_a_year_in_the_name_is_taken_as_its_year(self):
        posters.GET = web = Web({WIKI + "Donnie_Brasco_(1997_film)": summary("1997 film by Mike Newell")})
        filled = posters.fill({"type": "show", "items": [{"title": "Donnie Brasco (1997)"}]})
        self.assertEqual(filled["items"][0]["poster"], POSTER)
        self.assertEqual(filled["items"][0]["title"], "Donnie Brasco (1997)", "the name as the agent wrote it")

    def test_a_dead_poster_with_none_found_is_taken_off(self):
        posters.GET = Web({})
        filled = posters.fill(self.show(image="https://image.tmdb.org/x.jpg"))
        self.assertNotIn("image", filled["items"][0])
        self.assertNotIn("poster", filled["items"][0])

    def test_their_own_servers_poster_is_kept_beside_one_looked_up(self):
        posters.GET = web = Web({WIKI + "Donnie_Brasco_(1997_film)": summary("1997 film by Mike Newell")})
        jellyfin = "http://100.101.12.34:8096/Items/d77832c9/Images/Primary?tag=ad82a056"
        item = posters.fill(self.show(poster=jellyfin))["items"][0]
        self.assertEqual((item["own_poster"], item["poster"]), (jellyfin, POSTER), "Redde 2.8 shows the first, 2.7 the second")
        self.assertNotIn(jellyfin, web.asked, "never read from the server")
        posters.GET = Web({})
        item = posters.fill(self.show(poster=jellyfin))["items"][0]
        self.assertEqual((item["own_poster"], item.get("poster")), (jellyfin, None), "none found: only their own")
        for home in ("http://192.168.1.20/p.jpg", "https://jellyfin.example.ts.net/p.jpg", "http://nas:8096/p", "http://[fd7a:115c::1]/p"):
            self.assertTrue(posters.own(home), home)
        for outside in ("http://img.example.com/p.jpg", "https://8.8.8.8/p", "ftp://10.0.0.5/p", ""):
            self.assertFalse(posters.own(outside), outside)

    def test_an_outside_http_poster_is_looked_up(self):
        posters.GET = Web({WIKI + "Donnie_Brasco_(1997_film)": summary("1997 film by Mike Newell")})
        self.assertEqual(posters.fill(self.show(poster="http://img.example.com/p.jpg"))["items"][0]["poster"], POSTER)

    def test_one_that_cant_be_told_is_left_alone(self):
        posters.GET = Web({"https://jellyfin.example/p.jpg": ("refused", 0, "", b"")})
        filled = posters.fill(self.show(poster="https://jellyfin.example/p.jpg"))
        self.assertEqual(filled["items"][0]["poster"], "https://jellyfin.example/p.jpg", "a poster on the tailnet")

    def test_the_card_tool_hands_redde_the_card_with_its_poster(self):
        posters.GET = Web({WIKI + "Donnie_Brasco_(1997_film)": summary("1997 film by Mike Newell")})
        answer = json.loads(cards.handle({"cards": [self.show(poster="https://image.tmdb.org/t/p/w500/9366.jpg")]}))
        self.assertEqual(answer["cards"][0]["items"][0]["poster"], POSTER)
        self.assertTrue(answer["shown"][0].startswith("show: 1"))

    # 1.42.1 (2026-11-24: a film typed into a watch list with its last word small got no poster).
    SEARCH = "https://en.wikipedia.org/w/api.php?action=query&list=search&format=json&srlimit=5&srprop=&srinfo=suggestion&srsearch="

    def search(self, *titles, suggestion=None):
        found = {"query": {"search": [{"title": t} for t in titles], **({"searchinfo": {"suggestion": suggestion}} if suggestion else {})}}
        return ("ok", 200, "application/json", json.dumps(found).encode())

    def test_a_title_typed_with_small_letters_finds_its_page(self):
        posters.GET = Web({WIKI + "The_Polar_Express_(film)": summary("2004 film by Robert Zemeckis")})
        self.assertEqual(posters.lookup("The polar express", None, None, time.monotonic() + 5), POSTER)
        self.assertEqual(posters.cased("the lord of the rings: the fellowship of the ring"), "The Lord of the Rings: The Fellowship of the Ring")
        self.assertEqual(posters.cased("wicked: for good"), "Wicked: For Good")
        self.assertEqual(posters.cased("WALL-E"), "WALL-E")

    def test_the_search_finds_a_slip_of_the_keyboard_and_not_another_film(self):
        posters.GET = web = Web({self.SEARCH + quote("Wiked for Good film"): self.search("The Flying Ship (animated film)", "Wicked: For Good"),
                                 WIKI + "Wicked%3A_For_Good": summary("2025 film by Jon M. Chu"),
                                 WIKI + "The_Flying_Ship_(animated_film)": summary("1979 film", "https://upload.wikimedia.org/ship.jpg")})
        self.assertEqual(posters.lookup("Wiked for Good", None, None, time.monotonic() + 5), POSTER)
        self.assertNotIn(WIKI + "The_Flying_Ship_(animated_film)", web.asked, "a page named unlike the title isn't taken")

    def test_what_the_search_suggests_is_tried_when_no_page_is_the_title(self):
        posters.GET = Web({self.SEARCH + quote("Zootopai 2 film"): self.search("Zoo (film)", suggestion="Zootopia 2 film"),
                           self.SEARCH + quote("Zootopia 2 film"): self.search("Zootopia 2"),
                           WIKI + "Zootopia_2": summary("2025 animated film")})
        self.assertEqual(posters.lookup("Zootopai 2", None, None, time.monotonic() + 5), POSTER)

    def test_a_series_by_its_name_comes_before_the_search(self):
        shows = [{"show": {"name": "Severance", "premiered": "2022-02-18", "image": {"original": "https://static.tvmaze.com/sev.jpg"}}}]
        posters.GET = web = Web({"https://api.tvmaze.com/search/shows?q=severance": ("ok", 200, "application/json", json.dumps(shows).encode()),
                                 self.SEARCH + quote("severance film"): self.search("Severance (film)")})
        self.assertEqual(posters.lookup("severance", None, None, time.monotonic() + 5), "https://static.tvmaze.com/sev.jpg")
        self.assertFalse(any(url.startswith(self.SEARCH) for url in web.asked), "the search would take the film of that name")

    def test_names_are_alike_by_their_words(self):
        self.assertGreaterEqual(posters.alike("Zootopia two", "Zootopia 2 (2025 film)"), posters.ALIKE)
        self.assertGreaterEqual(posters.alike("the lord of the rings the fellowship of the ring", "The Lord of the Rings: The Fellowship of the Ring"), posters.ALIKE)
        self.assertLess(posters.alike("Wiked for Good", "The Flying Ship (animated film)"), posters.ALIKE)
        self.assertLess(posters.alike("Spider-Man: Into the Spider-Verse", "Spider-Man: Beyond the Spider-Verse"), posters.ALIKE)

    def test_it_doesnt_wait_long(self):
        def slow(url, deadline):
            time.sleep(0.2)
            return "unknown", 0, {}, b""
        posters.GET, posters.WAIT = slow, 0.5
        try:
            started = time.monotonic()
            posters.fill({"type": "show", "items": [{"title": f"T{n}"} for n in range(6)]})
            self.assertLess(time.monotonic() - started, 2.0)
        finally:
            posters.WAIT = 6.0



class TMDb:
    """TMDb's search, answering by the kind asked and the query, and what each call carried."""
    def __init__(self, movie=(), tv=(), status=200):
        self.results, self.status, self.asked = {"movie": list(movie), "tv": list(tv)}, status, []

    def __call__(self, url, deadline, headers=None):
        self.asked.append((url, headers))
        if url.startswith(posters.TMDB):
            kind = url[len(posters.TMDB):].split("?")[0]
            return "ok", self.status, {"content-type": "application/json"}, json.dumps({"results": self.results[kind]}).encode()
        return "ok", 404, {"content-type": "text/html"}, b""


class TMDbTests(unittest.TestCase):
    """1.44.0, 2026-11-24: "Let's do that with the key". With the person's own TMDb key, TMDb first."""
    KEY = "0123456789abcdef0123456789abcdef"

    def setUp(self):
        self.real, self.key = posters.GET, posters.KEY
        posters.KEY = lambda: self.KEY

    def tearDown(self):
        posters.GET, posters.KEY = self.real, self.key

    def find(self, title, year=None, series=None):
        return posters.lookup(title, year, series, time.monotonic() + 5)

    def test_a_film_comes_from_tmdb_with_its_page(self):
        posters.GET = web = TMDb(movie=[{"id": 10719, "title": "Elf", "release_date": "2003-10-09", "poster_path": "/elf.jpg", "popularity": 40}])
        found = self.find("Elf", "2003", False)
        self.assertEqual(found, posters.TMDB_IMAGES + "/elf.jpg")
        self.assertEqual(found.page, "https://www.themoviedb.org/movie/10719")
        url, headers = web.asked[0]
        self.assertIn("api_key=" + self.KEY, url)
        self.assertIsNone(headers)

    def test_a_read_access_token_goes_in_a_header_not_the_address(self):
        token = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ4In0.c2lnbmF0dXJl"
        posters.KEY = lambda: token
        posters.GET = web = TMDb(movie=[{"id": 1, "title": "Elf", "release_date": "2003-10-09", "poster_path": "/elf.jpg"}])
        self.assertTrue(self.find("Elf", None, False))
        url, headers = web.asked[0]
        self.assertNotIn(token, url)
        self.assertEqual(headers, {"Authorization": "Bearer " + token})

    def test_the_year_must_be_close_and_the_name_alike(self):
        posters.GET = TMDb(movie=[{"id": 2, "title": "Elf", "release_date": "1987-01-01", "poster_path": "/old.jpg"},
                                  {"id": 3, "title": "Elf Pets", "release_date": "2003-01-01", "poster_path": "/pets.jpg"}])
        self.assertIsNone(self.find("Elf", "2003", False), "another year's, and another film's, aren't it")

    def test_unknown_kind_takes_the_better_known(self):
        posters.GET = TMDb(movie=[{"id": 4, "title": "Severance", "release_date": "2006-08-25", "poster_path": "/film.jpg", "popularity": 3, "vote_count": 600}],
                           tv=[{"id": 95396, "name": "Severance", "first_air_date": "2022-02-17", "poster_path": "/series.jpg", "popularity": 200, "vote_count": 2500}])
        found = self.find("Severance")
        self.assertEqual(found, posters.TMDB_IMAGES + "/series.jpg")
        self.assertEqual(found.page, "https://www.themoviedb.org/tv/95396")

    def test_better_known_is_more_ratings_not_this_weeks_most_watched(self):
        # 2026-11-24: a Korean show called "Home Alone" and a Chinese one called "Love Actually",
        # on this week, took the films' places on a Christmas watch list.
        posters.GET = TMDb(movie=[{"id": 771, "title": "Home Alone", "release_date": "1990-11-16", "poster_path": "/film.jpg", "popularity": 30, "vote_count": 11000}],
                           tv=[{"id": 65282, "name": "Home Alone", "first_air_date": "2013-03-22", "poster_path": "/show.jpg", "popularity": 250, "vote_count": 40}])
        found = self.find("Home Alone")
        self.assertEqual(found.page, "https://www.themoviedb.org/movie/771")

    def test_a_wrong_key_or_no_match_falls_back_to_wikipedia(self):
        for web in (TMDb(status=401), TMDb()):
            posters.GET = web
            self.find("Donnie Brasco", "1997", False)
            self.assertTrue(any(url.startswith(WIKI) for url, _ in web.asked), "Wikipedia after TMDb")

    def test_no_key_no_tmdb(self):
        posters.KEY = lambda: None
        posters.GET = web = TMDb()
        self.find("Elf", "2003", False)
        self.assertFalse(any(url.startswith(posters.TMDB) for url, _ in web.asked))

    def test_the_key_is_read_from_a_profiles_env(self):
        import importlib
        import os
        import tempfile
        from pathlib import Path
        envs = importlib.import_module(plugin.__name__ + ".envs")
        names = posters.TMDB_NAMES
        saved = {n: os.environ.pop(n) for n in names if n in os.environ}
        try:
            with tempfile.TemporaryDirectory() as root:
                (Path(root) / ".env").write_text("OPENAI_API_KEY=sk-x\n")
                (Path(root) / "profiles" / "films").mkdir(parents=True)
                (Path(root) / "profiles" / "films" / ".env").write_text("export TMDB_API_KEY='abc123'\n")
                self.assertEqual(envs.key(Path(root), names), "abc123")
                (Path(root) / ".env").write_text("TMDB_READ_ACCESS_TOKEN=main\n")
                self.assertEqual(envs.key(Path(root), names), "main", "the main profile's first")
        finally:
            os.environ.update(saved)


if __name__ == "__main__":
    unittest.main()
