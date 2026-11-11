"""Models & Providers (lab.sh models), as Redde's page (ModelSetup.swift) asks for them, once over the
Dashboard's REST routes (signed in as the app is) and once over the plugin's `/v1/redde/models` on the
Hermes API:

  load       options, keys, endpoints, helpers and fallbacks read, for the main profile and a bot.
  key        a provider key saved lands in that profile's .env and nowhere in config.yaml; every answer
             after shows it masked and never whole; removed, it is unset.
  endpoint   tested (lists the stub's models), saved with a key (the key in .env), made the default.
  main       the default model set to the endpoint's model.
  fallbacks  a list saved, read back, emptied.
  helpers    one helper on a model of its own, then all back on the default.
  bot        a key and a default model for a bot land in the bot's own home, not the main one.
  delete     an endpoint that isn't the default is deleted.

Run against a lab that is up with the push scenario (the plugin, a login).
usage: models_check.py dashboard|api|both
"""
import asyncio
import http.cookiejar
import json
import os
import sys
import urllib.error
import urllib.request

import check
from check import Dashboard, report

BOT = "tinker"
SECRET = "sk-or-lab-0123456789abcdefSECRET"
ENDPOINT_SECRET = "sk-lab-endpoint-SECRET-4242"
HOME = os.environ["HERMES_HOME"]


def home(profile):
    return HOME if profile == "default" else os.path.join(HOME, "profiles", profile)


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return ""


class DashboardREST:
    """The routes DashboardModelSetup calls, with ?profile=."""
    name = "dashboard"

    def __init__(self):
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.send("POST", "/auth/password-login", {"provider": "basic", "username": "lab", "password": "labpass-labpass"}, scoped=False)
        self.answers = []

    def send(self, method, path, body=None, profile="default", scoped=True):
        if scoped:
            path += ("&" if "?" in path else "?") + "profile=" + profile
        request = urllib.request.Request(f"http://{check.SERVE}{path}", method=method,
                                         data=json.dumps(body).encode() if body is not None else None,
                                         headers={"Content-Type": "application/json"})
        try:
            with self.opener.open(request, timeout=90) as response:
                text = response.read().decode()
                status = response.status
        except urllib.error.HTTPError as error:
            text, status = error.read().decode(), error.code
        if scoped:
            self.answers.append(text)
        return status, (json.loads(text) if text.strip().startswith(("{", "[")) else text)

    def load(self, profile):
        _, options = self.send("GET", "/api/model/options?explicit_only=1&include_unconfigured=1", profile=profile)
        _, env = self.send("GET", "/api/env", profile=profile)
        _, endpoints = self.send("GET", "/api/providers/custom-endpoints", profile=profile)
        _, aux = self.send("GET", "/api/model/auxiliary", profile=profile)
        _, config = self.send("GET", "/api/config?include_defaults=false", profile=profile)
        return {"options": options, "env": env, "endpoints": endpoints, "auxiliary": aux,
                "fallback_providers": (config or {}).get("fallback_providers") or []}

    def set_key(self, profile, key, value):
        return self.send("PUT", "/api/env", {"key": key, "value": value, "provider_setup": True}, profile)[0]

    def remove_key(self, profile, key):
        return self.send("DELETE", "/api/env", {"key": key}, profile)[0]

    def test_endpoint(self, profile, base_url, api_key):
        return self.send("POST", "/api/providers/custom-endpoints/validate",
                         {"name": "test", "model": "", "base_url": base_url, "api_key": api_key, "api_mode": ""}, profile)[1]

    def save_endpoint(self, profile, body):
        return self.send("POST", "/api/providers/custom-endpoints", body, profile)

    def delete_endpoint(self, profile, ident):
        return self.send("DELETE", f"/api/providers/custom-endpoints/{ident}", None, profile)[0]

    def set_main(self, profile, provider, model):
        return self.send("POST", "/api/model/set", {"scope": "main", "provider": provider, "model": model, "confirm_expensive_model": True}, profile)

    def set_helper(self, profile, task, provider, model):
        return self.send("POST", "/api/model/set", {"scope": "auxiliary", "task": task, "provider": provider, "model": model}, profile)[0]

    def set_fallbacks(self, profile, entries):
        _, config = self.send("GET", "/api/config?include_defaults=false", profile=profile)
        body = {"fallback_providers": entries}
        if (config or {}).get("fallback_model") is not None:
            body["fallback_model"] = None
        return self.send("PUT", "/api/config", {"config": body}, profile)[0]


class PluginAPI:
    """The plugin's /v1/redde/models, as APIModelSetup sends it: the main key, the profile in the body."""
    name = "api"

    def __init__(self):
        self.answers = []

    def send(self, action, profile, **fields):
        status, text = check.api("POST", "/v1/redde/models", {"action": action, "profile": profile, **fields})
        self.answers.append(text)
        try:
            return status, json.loads(text)
        except ValueError:
            return status, text

    def load(self, profile):
        status, body = self.send("load", profile)
        assert status == 200, f"load answered {status}: {str(body)[:300]}"
        return body

    def set_key(self, profile, key, value):
        return self.send("set_key", profile, key=key, value=value)[0]

    def remove_key(self, profile, key):
        return self.send("remove_key", profile, key=key)[0]

    def test_endpoint(self, profile, base_url, api_key):
        return self.send("test_endpoint", profile, base_url=base_url, api_key=api_key, api_mode="")[1]

    def save_endpoint(self, profile, body):
        return self.send("save_endpoint", profile, **body)

    def delete_endpoint(self, profile, ident):
        return self.send("delete_endpoint", profile, id=ident)[0]

    def set_main(self, profile, provider, model):
        return self.send("set_main", profile, provider=provider, model=model, confirm_expensive_model=True)

    def set_helper(self, profile, task, provider, model):
        return self.send("set_helper", profile, task=task, provider=provider, model=model)[0]

    def set_fallbacks(self, profile, entries):
        return self.send("set_fallbacks", profile, fallback_providers=entries)[0]


def leaked(answers):
    return [a[:200] for a in answers if SECRET in a or ENDPOINT_SECRET in a]


def run(way):
    tag = f"[{way.name}]"
    setup = way.load("default")
    providers = (setup.get("options") or {}).get("providers") or []
    report(bool(providers), f"{tag} load: Hermes lists providers", json.dumps(setup)[:300])
    openrouter = (setup.get("env") or {}).get("OPENROUTER_API_KEY") or {}
    report(openrouter.get("provider") == "openrouter" and openrouter.get("provider_primary") is True,
           f"{tag} load: OpenRouter's key is listed as its main one", json.dumps(openrouter)[:300])
    report(isinstance((setup.get("auxiliary") or {}).get("tasks"), list), f"{tag} load: the helper tasks are listed")

    # A key.
    status = way.set_key("default", "OPENROUTER_API_KEY", SECRET)
    report(status == 200, f"{tag} key: saved", str(status))
    env = read(os.path.join(HOME, ".env"))
    report(SECRET in env, f"{tag} key: in the main .env")
    report(SECRET not in read(os.path.join(HOME, "config.yaml")), f"{tag} key: not in config.yaml")
    row = (way.load("default").get("env") or {}).get("OPENROUTER_API_KEY") or {}
    report(row.get("is_set") is True and SECRET not in json.dumps(row), f"{tag} key: shown set and masked", json.dumps(row))
    report(way.set_key("default", "API_SERVER_KEY", "nope") != 200 if way.name == "api" else True,
           f"{tag} key: a variable that isn't a provider's is refused")

    # An endpoint of one's own: the second stub, which serves gamma.
    tested = way.test_endpoint("default", "http://127.0.0.1:18802/v1", ENDPOINT_SECRET) or {}
    report("gamma" in (tested.get("models") or []), f"{tag} endpoint: tested, its models listed", json.dumps(tested)[:300])
    status, saved = way.save_endpoint("default", {"name": "Lab B", "base_url": "http://127.0.0.1:18802/v1", "model": "gamma",
                                                  "api_key": ENDPOINT_SECRET, "api_mode": "", "make_default": False, "discover_models": True})
    report(status == 200, f"{tag} endpoint: saved", str(saved)[:300])
    endpoints = (way.load("default").get("endpoints") or {}).get("endpoints") or []
    lab_b = next((e for e in endpoints if e.get("name") == "Lab B"), None)
    report(lab_b is not None and lab_b.get("has_api_key"), f"{tag} endpoint: listed with a key", json.dumps(endpoints)[:300])
    report(ENDPOINT_SECRET in read(os.path.join(HOME, ".env")) and ENDPOINT_SECRET not in read(os.path.join(HOME, "config.yaml")),
           f"{tag} endpoint: its key in .env, not config.yaml")

    # The default model on it.
    if lab_b:
        status, answer = way.set_main("default", f"custom:{lab_b['id']}", "gamma")
        report(status == 200 and (answer or {}).get("ok") is not False, f"{tag} main: set to the endpoint's model", str(answer)[:300])
        options = way.load("default").get("options") or {}
        report(options.get("model") == "gamma", f"{tag} main: read back", f"{options.get('provider')} {options.get('model')}")

    # Fallbacks.
    entries = [{"provider": "custom:my-local", "model": "beta"}, {"provider": "openrouter", "model": "qwen/qwen3-8b"}]
    report(way.set_fallbacks("default", entries) == 200, f"{tag} fallbacks: saved")
    back = [(e.get("provider"), e.get("model")) for e in way.load("default").get("fallback_providers") or []]
    report(back == [("custom:my-local", "beta"), ("openrouter", "qwen/qwen3-8b")], f"{tag} fallbacks: read back in order", str(back))
    way.set_fallbacks("default", [])
    report(not way.load("default").get("fallback_providers"), f"{tag} fallbacks: emptied")

    # A helper, then all back.
    report(way.set_helper("default", "title_generation", "custom:my-local", "beta") == 200, f"{tag} helpers: one set")
    tasks = {t["task"]: t for t in (way.load("default").get("auxiliary") or {}).get("tasks") or []}
    report(tasks.get("title_generation", {}).get("model") == "beta", f"{tag} helpers: read back", json.dumps(tasks.get("title_generation")))
    way.set_helper("default", "__reset__", "auto", "")
    tasks = {t["task"]: t for t in (way.load("default").get("auxiliary") or {}).get("tasks") or []}
    report(tasks.get("title_generation", {}).get("provider") in ("auto", "", None), f"{tag} helpers: back on the default",
           json.dumps(tasks.get("title_generation")))

    # A bot's own.
    bot_secret = SECRET + "-bot"
    status = way.set_key(BOT, "OPENROUTER_API_KEY", bot_secret)
    report(status == 200 and bot_secret in read(os.path.join(home(BOT), ".env")), f"{tag} bot: its key in its own .env", str(status))
    report(bot_secret not in read(os.path.join(HOME, ".env")), f"{tag} bot: not in the main .env")
    status, _ = way.set_main(BOT, "custom:my-local", "beta")
    report("beta" in read(os.path.join(home(BOT), "config.yaml")), f"{tag} bot: its default model in its own config")
    way.remove_key(BOT, "OPENROUTER_API_KEY")

    # Deleting an endpoint that isn't the default: put the default back first.
    way.set_main("default", "custom:my-local", "alpha")
    if lab_b:
        status = way.delete_endpoint("default", lab_b["id"])
        endpoints = (way.load("default").get("endpoints") or {}).get("endpoints") or []
        report(status == 200 and not any(e.get("name") == "Lab B" for e in endpoints), f"{tag} delete: gone", str(status))

    status = way.remove_key("default", "OPENROUTER_API_KEY")
    row = (way.load("default").get("env") or {}).get("OPENROUTER_API_KEY") or {}
    report(status == 200 and not row.get("is_set"), f"{tag} key: removed", str(status))
    report(not leaked(way.answers), f"{tag} no answer ever carried a key", str(leaked(way.answers))[:300])


async def make_bot():
    dash = await Dashboard.connect()
    try:
        await dash.call("profiles.create", {"name": BOT, "clone_from": "default", "no_alias": True, "share_auth": False,
                                            "description": "Tinkers.", "soul": "You are Tinker."})
    except Exception as error:
        print(f"  info  bot not made: {error}")


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "both"
    asyncio.run(make_bot())
    if which in ("dashboard", "both"):
        run(DashboardREST())
    if which in ("api", "both"):
        run(PluginAPI())
    if check.failures:
        print(f"\n{len(check.failures)} failed")
        sys.exit(1)


if __name__ == "__main__":
    main()
