"""python -m unittest discover -s companion/hermes-plugin/tests

A show card's posters, checked and found on the server (1.36.2, 2026-11-22: Sol built a TMDb
address for Donnie Brasco's poster from the film's id, and the card showed no poster)."""
import json
import time
import unittest

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
        self.real = posters.GET

    def tearDown(self):
        posters.GET = self.real

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


if __name__ == "__main__":
    unittest.main()
