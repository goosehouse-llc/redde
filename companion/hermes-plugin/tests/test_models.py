"""python -m unittest discover -s companion/hermes-plugin/tests

Models & providers over the Hermes API (redde-push/models.py, 1.26.0): `POST /v1/redde/models`
does what the Dashboard's settings routes do, in the asked profile's own home, and never hands
back a key: only provider keys are set, a «redacted» preview is refused, a plaintext key in
config.yaml never reaches an answer, fallbacks are replaced whole keeping what each had, the main
model's endpoint isn't removed from under it, and a bot's write lands in profiles/<bot>.

Needs Hermes's own Python (the lab's .venv): it calls Hermes's functions, in a scratch home."""
import asyncio
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_work import plugin

models = plugin.model_settings

try:
    import hermes_cli.config  # noqa: F401
    HERMES = True
except ImportError:
    HERMES = False

MAIN_KEY = "sk-PLAINTEXT-MAIN-" + "q8rT2vW6yB0nD4hK"
AUX_KEY = "sk-PLAINTEXT-AUX-" + "Zq8rT2vW6yB0nD4h"
FALLBACK_KEY = "sk-PLAINTEXT-FB-" + "W6yB0nD4hK7mP1sX"
ENDPOINT_KEY = "sk-PLAINTEXT-PROV-" + "nD4hK7mP1sX5Zq8r"
ROUTER_KEY = "sk-or-ENVSECRET-" + "7mP1sX5Zq8rT2vW6"
CUSTOM_KEY = "sk-custom-ENV-" + "1sX5Zq8rT2vW6yB0"
SERVER_KEY = "server-SECRET-" + "X5Zq8rT2vW6yB0nD"
SECRETS = (MAIN_KEY, AUX_KEY, FALLBACK_KEY, ENDPOINT_KEY, ROUTER_KEY, CUSTOM_KEY, SERVER_KEY)

CONFIG = f"""
model:
  provider: openrouter
  default: anthropic/claude-sonnet-4.5
  api_key: {MAIN_KEY}
auxiliary:
  vision:
    provider: openrouter
    model: google/gemini-2.5-flash
    api_key: {AUX_KEY}
fallback_providers:
  - provider: openrouter
    model: openai/gpt-5
    api_key: {FALLBACK_KEY}
    api_mode: chat_completions
    key_env: OPENROUTER_API_KEY
fallback_model:
  provider: nous
  model: hermes-4
providers:
  mylocal:
    name: My Local
    base_url: http://127.0.0.1:9/v1
    model: qwen
    api_key: {ENDPOINT_KEY}
  spare:
    name: Spare
    base_url: http://127.0.0.1:10/v1
    model: llama
    key_env: HERMES_CUSTOM_SPARE_API_KEY
"""
ENV = f"OPENROUTER_API_KEY={ROUTER_KEY}\nHERMES_CUSTOM_MYLOCAL_API_KEY={CUSTOM_KEY}\nHERMES_CUSTOM_SPARE_API_KEY={CUSTOM_KEY}x\nAPI_SERVER_KEY={SERVER_KEY}\n"

DENIED = object()


class FakeRequest:
    def __init__(self, body, token="good"):
        self.body, self.token = body, token

    async def json(self):
        if isinstance(self.body, Exception):
            raise self.body
        return self.body


class FakeApi:
    """The gateway's API server as models.py uses it: its auth check and its profile scope (the
    real one, from gateway/platforms/api_server.py, when this Hermes has it)."""

    def __init__(self):
        try:
            from gateway.platforms.api_server import APIServerAdapter
            self._profile_scope = APIServerAdapter._profile_scope
        except Exception:
            self._profile_scope = None

    def _check_auth(self, request):
        return None if request.token == "good" else DENIED


class FakeApp:
    class Router:
        def __init__(self):
            self.routes = {}

        def add_route(self, method, path, handler):
            self.routes[(method, path)] = handler

    def __init__(self):
        self.router = self.Router()


def fake_options(refresh=False):
    """The picker's list, stood in for (the real one warms catalogs over the network), with a key
    where none should be, to be scrubbed."""
    return {"model": "anthropic/claude-sonnet-4.5", "provider": "openrouter",
            "providers": [{"slug": "openrouter", "name": "OpenRouter", "models": ["openai/gpt-5"],
                           "key_env": "OPENROUTER_API_KEY", "api_key": ROUTER_KEY, "refresh_token": "rt-" + ROUTER_KEY,
                           "is_current": True, "refreshed": refresh}]}


@unittest.skipUnless(HERMES, "needs Hermes's own Python")
class ModelsTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.home = Path(self.dir.name) / "hermes"
        self.home.mkdir()
        (self.home / "config.yaml").write_text(CONFIG)
        (self.home / ".env").write_text(ENV)
        self.bot = self.home / "profiles" / "scout"
        self.bot.mkdir(parents=True)
        (self.bot / "config.yaml").write_text("model:\n  provider: openrouter\n  default: openai/gpt-5\n")
        (self.bot / ".env").write_text("API_SERVER_KEY=bot-key\n")
        env = mock.patch.dict(os.environ, {"HERMES_HOME": str(self.home)})
        env.start()
        self.addCleanup(env.stop)
        self.addCleanup(self.dir.cleanup)
        options = mock.patch.object(models, "options", fake_options)
        options.start()
        self.addCleanup(options.stop)
        self.api = FakeApi()
        app = FakeApp()
        models.wire()(app, self.api)
        self.handle = app.router.routes[("POST", models.ROUTE)]

    def ask(self, body, token="good"):
        answer = asyncio.run(self.handle(FakeRequest(body, token)))
        if answer is DENIED:
            return None, DENIED
        return answer.status, json.loads(answer.text)

    def raw(self, home=None):
        import hermes_yaml
        return hermes_yaml.safe_load(((home or self.home) / "config.yaml").read_text()) or {}

    def env(self, home=None):
        return ((home or self.home) / ".env").read_text()

    # --- keys -------------------------------------------------------------------------------

    def test_only_provider_keys_are_allowed(self):
        self.assertTrue(models.key_allowed("OPENROUTER_API_KEY"))
        self.assertTrue(models.key_allowed("HERMES_CUSTOM_MYLOCAL_API_KEY"))
        self.assertTrue(models.key_allowed("HERMES_CUSTOM_API_KEY"))
        for refused in ("API_SERVER_KEY", "PATH", "LD_PRELOAD", "OPENROUTER_BASE_URL", "TELEGRAM_BOT_TOKEN",
                        "HERMES_CUSTOM_X", "hermes_custom_x_api_key", ""):
            self.assertFalse(models.key_allowed(refused), refused)

    def test_a_provider_key_is_set_in_the_env_and_not_answered(self):
        status, answer = self.ask({"action": "set_key", "profile": "default", "key": "ANTHROPIC_API_KEY", "value": "sk-ant-NEW-12345678"})
        self.assertEqual(status, 200, answer)
        self.assertEqual(answer, {"ok": True, "key": "ANTHROPIC_API_KEY"})
        self.assertIn("ANTHROPIC_API_KEY=sk-ant-NEW-12345678", self.env())
        self.assertNotIn("sk-ant-NEW", json.dumps(self.raw()))

    def test_a_custom_endpoint_key_is_set(self):
        status, _ = self.ask({"action": "set_key", "key": "HERMES_CUSTOM_MYLOCAL_API_KEY", "value": "sk-new-custom-1234"})
        self.assertEqual(status, 200)
        self.assertIn("HERMES_CUSTOM_MYLOCAL_API_KEY=sk-new-custom-1234", self.env())

    def test_any_other_variable_is_refused(self):
        before = self.env()
        for key in ("API_SERVER_KEY", "PATH", "SOME_RANDOM_VAR"):
            status, answer = self.ask({"action": "set_key", "key": key, "value": "x-value-123456"})
            self.assertEqual(status, 400, key)
            self.assertIn("isn't a provider's API key", answer["error"]["message"])
        status, _ = self.ask({"action": "remove_key", "key": "API_SERVER_KEY"})
        self.assertEqual(status, 400)
        self.assertEqual(self.env(), before)

    def test_a_redacted_preview_is_never_saved(self):
        before = self.env()
        for preview in ("«redacted:sk-o...7890»", "«redacted-secret»", "sk-o...7890", "***", "${OPENROUTER_API_KEY}"):
            status, answer = self.ask({"action": "set_key", "key": "OPENROUTER_API_KEY", "value": preview})
            self.assertEqual(status, 400, preview)
            self.assertIn("redacted", answer["error"]["message"])
        status, _ = self.ask({"action": "set_key", "key": "OPENROUTER_API_KEY", "value": "  "})
        self.assertEqual(status, 400)
        self.assertEqual(self.env(), before)

    def test_a_key_is_removed_and_a_missing_one_is_404(self):
        status, answer = self.ask({"action": "remove_key", "key": "OPENROUTER_API_KEY"})
        self.assertEqual((status, answer), (200, {"ok": True, "key": "OPENROUTER_API_KEY"}))
        self.assertNotIn("OPENROUTER_API_KEY=", self.env())
        status, answer = self.ask({"action": "remove_key", "key": "OPENROUTER_API_KEY"})
        self.assertEqual(status, 404)
        self.assertIn("not found", answer["error"]["message"])

    # --- load -------------------------------------------------------------------------------

    def test_load_never_holds_a_secret(self):
        status, answer = self.ask({"action": "load", "profile": "default"})
        self.assertEqual(status, 200, answer)
        text = json.dumps(answer, ensure_ascii=False)
        for secret in SECRETS:
            self.assertNotIn(secret, text)
        self.assertEqual(set(answer), {"options", "env", "endpoints", "auxiliary", "fallback_providers", "plugin_version"})
        self.assertEqual(answer["plugin_version"], models.plugin_version())
        self.assertTrue(answer["plugin_version"])
        # The picker's list, scrubbed of the key it shouldn't have had.
        row = answer["options"]["providers"][0]
        self.assertEqual(row["key_env"], "OPENROUTER_API_KEY")
        self.assertNotIn("api_key", row)
        self.assertNotIn("refresh_token", row)
        # Provider keys only, each a preview.
        env = answer["env"]
        self.assertTrue(env["OPENROUTER_API_KEY"]["is_set"])
        self.assertTrue(env["OPENROUTER_API_KEY"]["redacted_value"].startswith("«redacted"))
        self.assertEqual(env["OPENROUTER_API_KEY"]["provider"], "openrouter")
        # (The app lists a provider's key by these two, as GET /api/env gives them.)
        self.assertIs(env["OPENROUTER_API_KEY"]["provider_primary"], True)
        self.assertTrue(env["OPENROUTER_API_KEY"]["provider_label"])
        with open(self.home / ".env", "a") as dotenv:
            dotenv.write("TELEGRAM_BOT_TOKEN=bot-token-123456\nMY_OWN_THING=abc\n")
        again = self.ask({"action": "load"})[1]["env"]
        self.assertNotIn("MY_OWN_THING", again, "an arbitrary .env key isn't a provider's")
        self.assertFalse(again.get("TELEGRAM_BOT_TOKEN", {}).get("custom"))
        self.assertTrue(all(row["provider"] or (name.startswith("HERMES_CUSTOM_") and row["custom"]) for name, row in again.items()))
        self.assertTrue(env["HERMES_CUSTOM_MYLOCAL_API_KEY"]["custom"])
        self.assertNotIn("API_SERVER_KEY", env)
        self.assertTrue(all(row["provider"] or row["custom"] for row in env.values()))
        # Endpoints as the Dashboard lists them.
        rows = {e["id"]: e for e in answer["endpoints"]["endpoints"]}
        self.assertEqual(set(rows), {"mylocal", "spare"})
        self.assertTrue(rows["mylocal"]["has_api_key"])
        self.assertTrue(rows["mylocal"]["api_key_preview"].startswith("«redacted"))
        self.assertEqual(rows["spare"]["api_key_preview"], "${HERMES_CUSTOM_SPARE_API_KEY}")
        self.assertEqual(answer["endpoints"]["current"]["provider"], "openrouter")
        # Helpers, and the main model.
        tasks = {t["task"]: t for t in answer["auxiliary"]["tasks"]}
        self.assertEqual(tasks["vision"]["model"], "google/gemini-2.5-flash")
        self.assertEqual(tasks["compression"]["provider"], "auto")
        self.assertEqual(answer["auxiliary"]["main"], {"provider": "openrouter", "model": "anthropic/claude-sonnet-4.5"})
        # Fallbacks: the list first, then the legacy one; three fields, never a key.
        self.assertEqual(answer["fallback_providers"], [{"provider": "openrouter", "model": "openai/gpt-5"},
                                                        {"provider": "nous", "model": "hermes-4"}])

    def test_refresh_reaches_the_picker(self):
        _, answer = self.ask({"action": "load", "refresh": True})
        self.assertTrue(answer["options"]["providers"][0]["refreshed"])

    def test_scrub_keeps_flags_and_previews(self):
        scrubbed = models.scrub({"has_api_key": True, "api_key_preview": "«redacted:x»", "api_key": "k",
                                 "nested": [{"client_secret": "s", "max_tokens": 5, "key_env": "X"}], "github_token": "t"})
        self.assertEqual(scrubbed, {"has_api_key": True, "api_key_preview": "«redacted:x»",
                                    "nested": [{"max_tokens": 5, "key_env": "X"}]})

    # --- fallbacks --------------------------------------------------------------------------

    def test_fallbacks_are_replaced_whole_keeping_what_each_had(self):
        status, answer = self.ask({"action": "set_fallbacks", "fallback_providers": [
            {"provider": "anthropic", "model": "claude-opus-4.5", "api_key": "sk-sent-by-mistake-123"},
            {"provider": "openrouter", "model": "openai/gpt-5"},
            {"provider": "openrouter"},
            {"model": "lonely"},
            {"provider": "openrouter", "model": "openai/gpt-5"},
            {"provider": "custom", "model": "llama", "base_url": "http://127.0.0.1:11/v1"},
        ]})
        self.assertEqual(status, 200, answer)
        self.assertEqual(answer["fallback_providers"], [
            {"provider": "anthropic", "model": "claude-opus-4.5"},
            {"provider": "openrouter", "model": "openai/gpt-5"},
            {"provider": "custom", "model": "llama", "base_url": "http://127.0.0.1:11/v1"}])
        raw = self.raw()
        chain = raw["fallback_providers"]
        self.assertEqual([(e["provider"], e["model"]) for e in chain],
                         [("anthropic", "claude-opus-4.5"), ("openrouter", "openai/gpt-5"), ("custom", "llama")])
        self.assertEqual(chain[0], {"provider": "anthropic", "model": "claude-opus-4.5"}, "nothing sent beyond the three fields")
        self.assertEqual(chain[1]["api_mode"], "chat_completions")
        self.assertEqual(chain[1]["key_env"], "OPENROUTER_API_KEY")
        self.assertNotIn("fallback_model", raw)
        self.assertNotIn("sk-sent-by-mistake", (self.home / "config.yaml").read_text())
        # Everything else in config.yaml stays.
        self.assertEqual(raw["model"]["default"], "anthropic/claude-sonnet-4.5")
        self.assertIn("mylocal", raw["providers"])

    def test_an_empty_list_clears_the_chain(self):
        status, answer = self.ask({"action": "set_fallbacks", "fallback_providers": []})
        self.assertEqual((status, answer["fallback_providers"]), (200, []))
        self.assertEqual(self.raw().get("fallback_providers") or [], [])
        _, answer = self.ask({"action": "load"})
        self.assertEqual(answer["fallback_providers"], [])

    def test_fallbacks_must_be_a_list(self):
        status, _ = self.ask({"action": "set_fallbacks", "fallback_providers": {"provider": "x", "model": "y"}})
        self.assertEqual(status, 400)

    # --- endpoints --------------------------------------------------------------------------

    def test_the_main_models_endpoint_is_not_removed(self):
        (self.home / "config.yaml").write_text(CONFIG.replace("provider: openrouter\n  default: anthropic/claude-sonnet-4.5",
                                                              "provider: mylocal\n  default: qwen", 1))
        status, answer = self.ask({"action": "delete_endpoint", "id": "mylocal"})
        self.assertEqual(status, 409)
        self.assertIn("main model", answer["error"]["message"])
        self.assertIn("mylocal", self.raw()["providers"])
        self.assertIn("HERMES_CUSTOM_MYLOCAL_API_KEY=", self.env())

    def test_another_endpoint_is_removed_with_its_key(self):
        status, answer = self.ask({"action": "delete_endpoint", "id": "spare"})
        self.assertEqual(status, 200, answer)
        self.assertTrue(answer["ok"])
        self.assertEqual([e["id"] for e in answer["endpoints"]], ["mylocal"])
        self.assertNotIn("spare", self.raw()["providers"])
        self.assertNotIn("HERMES_CUSTOM_SPARE_API_KEY=", self.env())
        status, _ = self.ask({"action": "delete_endpoint", "id": "spare"})
        self.assertEqual(status, 404)

    def test_an_endpoints_key_goes_to_the_env_never_the_config(self):
        status, answer = self.ask({"action": "save_endpoint", "name": "Lab Box", "base_url": "http://127.0.0.1:12/v1/",
                                   "model": "qwen3", "api_key": "sk-lab-box-12345678", "models": ["qwen3", "gemma"]})
        self.assertEqual(status, 200, answer)
        self.assertEqual(answer["id"], "lab-box")
        self.assertTrue(answer["ok"])
        entry = self.raw()["providers"]["lab-box"]
        self.assertEqual(entry["base_url"], "http://127.0.0.1:12/v1")
        self.assertEqual(entry["key_env"], "HERMES_CUSTOM_LAB_BOX_API_KEY")
        self.assertNotIn("api_key", entry)
        self.assertEqual(set(entry["models"]), {"qwen3", "gemma"})
        self.assertIn("HERMES_CUSTOM_LAB_BOX_API_KEY=sk-lab-box-12345678", self.env())
        self.assertNotIn("sk-lab-box", (self.home / "config.yaml").read_text())
        self.assertNotIn("sk-lab-box", json.dumps(answer))
        # Saved again with no key, it keeps it; with "", it's cleared.
        self.ask({"action": "save_endpoint", "id": "lab-box", "name": "Lab Box", "base_url": "http://127.0.0.1:12/v1", "model": "gemma"})
        self.assertIn("HERMES_CUSTOM_LAB_BOX_API_KEY=sk-lab-box-12345678", self.env())
        self.assertEqual(self.raw()["providers"]["lab-box"]["model"], "gemma")
        self.ask({"action": "save_endpoint", "id": "lab-box", "name": "Lab Box", "base_url": "http://127.0.0.1:12/v1", "model": "gemma", "api_key": ""})
        self.assertNotIn("HERMES_CUSTOM_LAB_BOX_API_KEY=", self.env())
        self.assertNotIn("key_env", self.raw()["providers"]["lab-box"])

    def test_an_endpoint_without_a_host_is_refused(self):
        status, answer = self.ask({"action": "save_endpoint", "name": "Bad", "base_url": "not a url", "model": "m"})
        self.assertEqual(status, 400)
        self.assertIn("base_url", answer["error"]["message"])
        status, _ = self.ask({"action": "save_endpoint", "name": "Bad", "base_url": "http://h", "model": "m", "api_mode": "nonsense"})
        self.assertEqual(status, 400)

    def test_activating_an_older_endpoint_moves_its_key_out_of_the_config(self):
        status, answer = self.ask({"action": "activate_endpoint", "id": "mylocal"})
        self.assertEqual((status, answer), (200, {"ok": True, "provider": "mylocal", "model": "qwen"}))
        raw = self.raw()
        self.assertEqual((raw["model"]["provider"], raw["model"]["default"]), ("mylocal", "qwen"))
        self.assertEqual(raw["model"]["key_env"], "HERMES_CUSTOM_MYLOCAL_API_KEY")
        self.assertNotIn("api_key", raw["model"])
        self.assertNotIn("api_key", raw["providers"]["mylocal"])
        self.assertNotIn(ENDPOINT_KEY, (self.home / "config.yaml").read_text())
        self.assertIn(f"HERMES_CUSTOM_MYLOCAL_API_KEY={ENDPOINT_KEY}", self.env())

    def test_an_endpoint_key_kept_as_a_template_is_copied_as_one(self):
        (self.home / "config.yaml").write_text(CONFIG.replace(f"api_key: {ENDPOINT_KEY}", "api_key: ${MY_LOCAL_KEY}"))
        with open(self.home / ".env", "a") as env:
            env.write(f"MY_LOCAL_KEY={ENDPOINT_KEY}\n")
        status, _ = self.ask({"action": "activate_endpoint", "id": "mylocal"})
        self.assertEqual(status, 200)
        self.assertEqual(self.raw()["model"]["api_key"], "${MY_LOCAL_KEY}")
        self.assertNotIn(ENDPOINT_KEY, (self.home / "config.yaml").read_text())

    def test_the_main_model_on_an_older_endpoint_never_copies_its_key(self):
        status, answer = self.ask({"action": "set_main", "provider": "mylocal", "model": "qwen", "confirm_expensive_model": True})
        self.assertEqual(status, 200, answer)
        self.assertTrue(answer["ok"])
        self.assertIn("stale_aux", answer)
        self.assertEqual(self.raw()["model"]["provider"], "mylocal")
        self.assertNotIn(ENDPOINT_KEY, (self.home / "config.yaml").read_text())
        self.assertIn(f"HERMES_CUSTOM_MYLOCAL_API_KEY={ENDPOINT_KEY}", self.env())

    def test_an_unknown_endpoint_is_not_activated(self):
        status, _ = self.ask({"action": "activate_endpoint", "id": "nowhere"})
        self.assertEqual(status, 404)
        status, _ = self.ask({"action": "activate_endpoint"})
        self.assertEqual(status, 400)

    # --- main model and helpers ---------------------------------------------------------------

    def test_a_key_is_never_taken_for_the_main_model_or_a_helper(self):
        for action in ("set_main", "set_helper"):
            status, answer = self.ask({"action": action, "provider": "openrouter", "model": "x", "api_key": "sk-inline-123"})
            self.assertEqual(status, 400, action)
            self.assertIn("set_key", answer["error"]["message"])
        self.assertNotIn("sk-inline", (self.home / "config.yaml").read_text())

    def test_helpers_reset_to_auto(self):
        status, answer = self.ask({"action": "set_helper", "task": "__reset__", "provider": "", "model": ""})
        self.assertEqual(status, 200, answer)
        self.assertTrue(answer["reset"])
        self.assertEqual(self.raw()["auxiliary"]["vision"]["provider"], "auto")

    def test_an_unknown_helper_task_is_400(self):
        status, answer = self.ask({"action": "set_helper", "task": "nonsense", "provider": "openrouter", "model": "x"})
        self.assertEqual(status, 400)
        self.assertIn("unknown auxiliary task", answer["error"]["message"])

    # --- profiles ---------------------------------------------------------------------------

    def test_a_bots_writes_land_in_its_own_home(self):
        status, _ = self.ask({"action": "set_key", "profile": "scout", "key": "ANTHROPIC_API_KEY", "value": "sk-ant-BOT-12345678"})
        self.assertEqual(status, 200)
        self.assertIn("ANTHROPIC_API_KEY=sk-ant-BOT-12345678", self.env(self.bot))
        self.assertNotIn("sk-ant-BOT", self.env())
        self.assertNotIn("sk-ant-BOT", os.environ.get("ANTHROPIC_API_KEY", ""), "a bot's key stays out of the gateway's own env")
        status, _ = self.ask({"action": "set_fallbacks", "profile": "Scout", "fallback_providers": [{"provider": "nous", "model": "hermes-4"}]})
        self.assertEqual(status, 200)
        self.assertEqual(self.raw(self.bot)["fallback_providers"], [{"provider": "nous", "model": "hermes-4"}])
        self.assertEqual(self.raw()["fallback_providers"][0]["model"], "openai/gpt-5", "the main profile's chain untouched")
        status, answer = self.ask({"action": "load", "profile": "scout"})
        self.assertEqual(status, 200)
        self.assertEqual(answer["auxiliary"]["main"]["model"], "openai/gpt-5")
        self.assertEqual(answer["endpoints"]["endpoints"], [])
        self.assertTrue(answer["env"]["ANTHROPIC_API_KEY"]["is_set"])
        self.assertFalse(answer["env"]["OPENROUTER_API_KEY"]["is_set"], "the main profile's key isn't the bot's")

    def test_a_bots_home_is_used_even_when_the_scope_doesnt_switch_it(self):
        self.api._profile_scope = None
        status, _ = self.ask({"action": "set_key", "profile": "scout", "key": "DEEPSEEK_API_KEY", "value": "gsk-BOT-12345678"})
        self.assertEqual(status, 200)
        self.assertIn("DEEPSEEK_API_KEY=gsk-BOT-12345678", self.env(self.bot))
        self.assertNotIn("gsk-BOT", self.env())

    def test_an_unknown_profile_is_404(self):
        for profile in ("nobody", "../etc", "Bad Name"):
            status, answer = self.ask({"action": "load", "profile": profile})
            self.assertEqual(status, 404, profile)
            self.assertEqual(answer["error"]["message"], f"No profile named {profile}.")
        status, _ = self.ask({"action": "test_endpoint", "profile": "nobody", "base_url": "http://127.0.0.1:9"})
        self.assertEqual(status, 404)

    # --- the route --------------------------------------------------------------------------

    def test_an_unknown_action_is_400(self):
        status, answer = self.ask({"action": "reveal", "key": "OPENROUTER_API_KEY"})
        self.assertEqual(status, 400)
        self.assertIn("Unknown action reveal", answer["error"]["message"])
        self.assertEqual(self.ask({"profile": "default"})[0], 400)
        self.assertEqual(self.ask(["load"])[0], 400)
        self.assertEqual(self.ask(ValueError("not JSON"))[0], 400)

    def test_a_denied_request_is_answered_by_the_gateway(self):
        before = self.env()
        status, answer = self.ask({"action": "set_key", "key": "OPENROUTER_API_KEY", "value": "sk-or-other-1234"}, token="bad")
        self.assertIs(answer, DENIED)
        self.assertEqual(self.env(), before)

    def test_a_missing_hermes_function_is_501(self):
        with mock.patch.dict(sys.modules, {"hermes_cli.credential_lifecycle": None}):
            status, answer = self.ask({"action": "set_key", "key": "OPENROUTER_API_KEY", "value": "sk-or-other-1234"})
        self.assertEqual(status, 501)
        self.assertEqual(answer["error"]["message"], "This Hermes doesn't have the credential lifecycle.")

    def test_an_endpoint_test_writes_nothing(self):
        before = ((self.home / "config.yaml").read_text(), self.env())
        status, answer = self.ask({"action": "test_endpoint", "base_url": ""})
        self.assertEqual(status, 200)
        self.assertEqual(answer["ok"], False)
        self.assertEqual(answer["models"], [])
        self.assertIn("resolved_base_url", answer)
        self.assertEqual(before, ((self.home / "config.yaml").read_text(), self.env()))


@unittest.skipUnless(HERMES, "needs Hermes's own Python")
class RegisteredTests(unittest.TestCase):
    def test_the_route_is_registered_on_the_api_server(self):
        app = FakeApp()
        models.wire()(app, FakeApi())
        self.assertIn(("POST", "/v1/redde/models"), app.router.routes)
        models.wire()(None, FakeApi())  # (no app: nothing, no error)

    def test_hermes_doesnt_take_it_for_the_command_route(self):
        # (Hermes skips a plugin's factory whose qualified name it has wired already.)
        self.assertNotEqual(models.wire().__qualname__, plugin.work_runs.wire(lambda command: "").__qualname__)


if __name__ == "__main__":
    unittest.main()
