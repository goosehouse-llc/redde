"""Models & providers over the Hermes API (1.26.0): what the Dashboard's settings routes do, for a
gateway that has none.

The Dashboard (`hermes serve`) has routes for a profile's provider keys (`/api/env`), its own
endpoints (`/api/providers/custom-endpoints`), its main model and helper models (`/api/model/…`)
and its config. The Hermes API (`api_server`) has none of them that write, so Redde's Models &
Providers screen would work on one connection only. This puts one route on the API server,
`POST /v1/redde/models` (`{"action": …, "profile": …}`, the main API key), that does the same
things with Hermes's own functions, in the profile's own home, and answers in the Dashboard's own
shapes, so the app reads one format.

What it never does: hand back a key (no reveal; a key shows as Hermes's «redacted» preview), write
a key into config.yaml (keys go to the profile's .env, as the Dashboard puts them), log a key or a
request, replace config.yaml but through Hermes's save_config, or restart anything. A Hermes that
lacks one of these functions is answered 501 for that action; the plugin loads all the same.
"""
from __future__ import annotations

import asyncio
import contextlib
import logging
import re
import threading
from pathlib import Path

log = logging.getLogger("redde-push")

ROUTE = "/v1/redde/models"

#: The plugin's own version, as plugin.yaml states it.
def plugin_version() -> str:
    try:
        text = (Path(__file__).resolve().parent / "plugin.yaml").read_text(encoding="utf-8")
    except OSError:
        return ""
    found = re.search(r"^version:\s*['\"]?([^'\"\s]+)", text, re.MULTILINE)
    return found.group(1) if found else ""


#: One config read-modify-write at a time from here (the Dashboard's _CONFIG_MUTATION_LOCK lives in
#: its own process; the gateway has none).
_LOCK = threading.RLock()

#: A custom endpoint's key in .env, as Hermes names it (`custom_endpoint_key_env`).
CUSTOM_KEY = re.compile(r"^HERMES_CUSTOM_(?:[A-Z0-9_]+_)?API_KEY$")
#: An env reference, as the Dashboard shows a key kept behind key_env: never a key itself.
ENV_REF = re.compile(r"^\$\{[^}]+\}$")

#: Field names whose value is a credential, wherever they turn up in what this answers with.
SECRET_FIELDS = frozenset({
    "api_key", "apikey", "token", "access_token", "refresh_token", "id_token", "secret",
    "client_secret", "password", "passwd", "authorization", "private_key", "bearer", "jwt"})
SECRET_SUFFIXES = ("_api_key", "_token", "_secret", "_password")


class Refusal(Exception):
    """An answer other than 200: its status and its message."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status, self.message = status, message


class Missing(Refusal):
    def __init__(self, what: str):
        super().__init__(501, f"This Hermes doesn't have {what}.")


def _need(module: str, *names: str, what: str):
    """Hermes's own functions, or a 501 naming what this Hermes lacks."""
    import importlib
    try:
        loaded = importlib.import_module(module)
        found = tuple(getattr(loaded, name) for name in names)
    except (ImportError, AttributeError):
        raise Missing(what) from None
    return found if len(found) != 1 else found[0]


def _secret_field(name, value) -> bool:
    """A credential-named field that could hold one (`has_api_key: true` is a flag, not a key)."""
    if not isinstance(name, str) or value is None or isinstance(value, (bool, int, float)):
        return False
    name = name.lower()
    return name in SECRET_FIELDS or name.endswith(SECRET_SUFFIXES)


def scrub(value):
    """A copy with every credential-named field taken out, all the way down."""
    if isinstance(value, dict):
        return {k: scrub(v) for k, v in value.items() if not _secret_field(k, v)}
    if isinstance(value, (list, tuple)):
        return [scrub(v) for v in value]
    return value


def _http_error(error: Exception) -> Refusal | None:
    """Hermes's own refusals (FastAPI's HTTPException, which the Dashboard helpers raise)."""
    status, detail = getattr(error, "status_code", None), getattr(error, "detail", None)
    if isinstance(status, int) and detail is not None:
        return Refusal(status, str(detail))
    return None


# --- the profile ---------------------------------------------------------------------------

def profile_name(raw) -> str | None:
    """None for the main profile, else the profile's id; 404 for one that doesn't exist."""
    text = str(raw or "").strip()
    if not text or text.lower() == "default":
        return None
    try:
        from hermes_cli.profiles import get_profile_dir, normalize_profile_name, profile_exists
        name = normalize_profile_name(text)
        if name == "default":
            return None
        if profile_exists(name):
            get_profile_dir(name)  # (refuses a name that isn't a profile id)
            return name
    except ImportError:
        raise Missing("profiles") from None
    except ValueError:
        pass
    raise Refusal(404, f"No profile named {text}.")


@contextlib.contextmanager
def scoped(api, name: str | None):
    """The profile's scope, as the gateway enters one for `/p/<profile>/`, and its home for config
    and .env, whatever the gateway's scope does (a named profile's writes land in its own home)."""
    scope = getattr(api, "_profile_scope", None)
    with (scope(name) if callable(scope) else contextlib.nullcontext()):
        token = None
        if name:
            from hermes_cli.profiles import get_profile_dir
            from hermes_constants import get_hermes_home, set_hermes_home_override
            home = get_profile_dir(name)
            if Path(get_hermes_home()).resolve() != Path(home).resolve():
                token = set_hermes_home_override(str(home))
        try:
            yield
        finally:
            if token is not None:
                from hermes_constants import reset_hermes_home_override
                reset_hermes_home_override(token)


# --- keys ----------------------------------------------------------------------------------

def _catalog_env() -> dict:
    """{env var: the Dashboard's provider card for it}, from Hermes's provider catalog."""
    meta = _need("hermes_cli.web_routers.config_env", "_catalog_provider_env_metadata",
                 what="the Dashboard's provider list")
    return meta() or {}


def key_allowed(key: str, catalog: dict | None = None) -> bool:
    """A catalog provider's API key, or a custom endpoint's key: nothing else is set from here."""
    if not isinstance(key, str) or not key:
        return False
    if CUSTOM_KEY.match(key):
        return True
    card = (catalog if catalog is not None else _catalog_env()).get(key) or {}
    return bool(card.get("provider")) and bool(card.get("is_password"))


def env_rows() -> dict:
    """GET /api/env's rows for the provider keys only: those with a provider, and custom
    endpoints' keys. Values only as Hermes's redacted preview."""
    load_env, optional = _need("hermes_cli.config", "load_env", "OPTIONAL_ENV_VARS", what="the .env reader")
    preview = _need("hermes_cli.web_routers._common", "redacted_credential_preview", what="redacted previews")
    on_disk = load_env() or {}
    catalog = _catalog_env()

    def row(var: str, info: dict, custom: bool = False) -> dict:
        value, card = on_disk.get(var), catalog.get(var) or {}
        return {
            "is_set": bool(value),
            "redacted_value": preview(value),
            "description": info.get("description") or card.get("description", ""),
            "url": info.get("url") if info.get("url") is not None else card.get("url"),
            "category": "custom" if custom else (info.get("category") or card.get("category", "")),
            "is_password": True if custom else info.get("password", card.get("is_password", False)),
            "tools": info.get("tools", []),
            "advanced": info.get("advanced", card.get("advanced", False)),
            "provider": card.get("provider", ""),
            "provider_label": card.get("provider_label", ""),
            "provider_profiles": card.get("provider_profiles", []),
            "provider_primary": bool(card.get("provider_primary", False)),
            "custom": custom,
        }

    rows = {var: row(var, (optional or {}).get(var) or {}) for var in catalog if catalog[var].get("provider")}
    for var in on_disk:
        if var not in rows and CUSTOM_KEY.match(var):
            rows[var] = row(var, {}, custom=True)
    return rows


def set_key(body: dict) -> dict:
    key, value = str(body.get("key") or "").strip(), body.get("value")
    if not key_allowed(key):
        raise Refusal(400, f"{key or 'That'} isn't a provider's API key; only those are set from here.")
    if not isinstance(value, str) or not value.strip():
        raise Refusal(400, "value is required (remove_key takes a key out)")
    is_preview = _need("hermes_cli.web_routers._common", "is_redacted_credential_preview", what="redacted previews")
    if is_preview(value) or ENV_REF.match(value.strip()):
        raise Refusal(400, "Refusing to save a redacted credential preview; re-enter the full secret to replace it.")
    save = _need("hermes_cli.credential_lifecycle", "save_provider_env_credential", what="the credential lifecycle")
    save(key, value)
    return {"ok": True, "key": key}


def remove_key(body: dict) -> dict:
    key = str(body.get("key") or "").strip()
    if not key_allowed(key):
        raise Refusal(400, f"{key or 'That'} isn't a provider's API key; only those are removed from here.")
    remove = _need("hermes_cli.credential_lifecycle", "remove_provider_env_credential", what="the credential lifecycle")
    result = remove(key) or {}
    if not result.get("found"):
        raise Refusal(404, f"{key} not found in .env")
    return {"ok": True, "key": key}


# --- what `load` reads ---------------------------------------------------------------------

def options(refresh: bool) -> dict:
    build, context = _need("hermes_cli.inventory", "build_model_options_payload", "load_picker_context",
                           what="the model picker's list")
    return build(context(), explicit_only=True, include_unconfigured=True, refresh=bool(refresh))


def endpoints() -> dict:
    load_config = _need("hermes_cli.config", "load_config", what="load_config")
    response = _need("hermes_cli.web_routers.config_env", "_custom_endpoint_response", what="custom endpoints")
    return response(load_config())


def auxiliary() -> dict:
    """GET /api/model/auxiliary, as the Dashboard builds it."""
    load_config = _need("hermes_cli.config", "load_config", what="load_config")
    slots, plugin_tasks = _need("hermes_cli.web_server_config", "_AUX_TASK_SLOTS", "_plugin_aux_tasks",
                                what="helper models")
    try:
        from agent.auxiliary_client import _get_auxiliary_task_config
    except ImportError:
        _get_auxiliary_task_config = None
    try:
        from agent.model_metadata import is_local_endpoint
    except ImportError:
        def is_local_endpoint(url):
            return False
    cfg = load_config()
    extra = plugin_tasks()
    effective = {}
    if _get_auxiliary_task_config is not None:
        for entry in extra:
            if entry.get("inherit_from"):
                with contextlib.suppress(Exception):
                    effective[entry["key"]] = _get_auxiliary_task_config(entry["key"]) or {}
    aux = cfg.get("auxiliary") if isinstance(cfg.get("auxiliary"), dict) else {}

    def row(slot: str) -> dict:
        slot_cfg = aux.get(slot) if isinstance(aux.get(slot), dict) else {}
        base_url = str(slot_cfg.get("base_url", "") or "")
        return {
            "task": slot, "provider": str(slot_cfg.get("provider", "auto") or "auto"),
            "model": str(slot_cfg.get("model", "") or ""), "base_url": base_url,
            "reasoning_effort": str(slot_cfg.get("reasoning_effort") or "") or None,
            "local_endpoint": bool(is_local_endpoint(base_url)),
        }

    tasks = [row(slot) for slot in slots]
    tasks.extend({
        **row(entry["key"]),
        "label": str(entry.get("display_name") or entry["key"]),
        "hint": str(entry.get("description") or ""),
        "plugin": str(entry.get("plugin") or ""),
        "inherit_from": entry.get("inherit_from") or None,
        **({"effective": {field: str(effective[entry["key"]].get(field) or "") for field in ("provider", "model", "base_url")}}
           if entry["key"] in effective else {}),
    } for entry in extra)
    model_cfg = cfg.get("model")
    if isinstance(model_cfg, dict):
        main_model, main_provider = model_cfg.get("default", model_cfg.get("name", "")), model_cfg.get("provider", "")
    else:
        main_model, main_provider = (str(model_cfg) if model_cfg else ""), ""
    return {"tasks": tasks, "main": {"provider": str(main_provider or ""), "model": str(main_model or "")}}


def _raw_config() -> dict:
    read = _need("hermes_cli.config", "read_raw_config", what="read_raw_config")
    raw = read()
    return raw if isinstance(raw, dict) else {}


def _chain(raw: dict) -> list[dict]:
    """The fallback chain as Hermes reads it: fallback_providers first, then the legacy
    fallback_model, the same route only once."""
    try:
        from hermes_cli.fallback_config import get_fallback_chain
        return [dict(e) for e in get_fallback_chain(raw) if isinstance(e, dict)]
    except ImportError:
        pass
    chain, seen = [], set()
    for key in ("fallback_providers", "fallback_model"):
        value = raw.get(key)
        for entry in ([value] if isinstance(value, dict) else value if isinstance(value, list) else []):
            if not isinstance(entry, dict):
                continue
            provider, model = str(entry.get("provider") or "").strip(), str(entry.get("model") or "").strip()
            if not provider or not model:
                continue
            base = str(entry.get("base_url") or "").strip().rstrip("/")
            identity = (provider.lower(), model.lower(), base.lower())
            if identity not in seen:
                seen.add(identity)
                chain.append({**entry, "provider": provider, "model": model, **({"base_url": base} if base else {})})
    return chain


def _shown(entry: dict) -> dict:
    """A fallback as the app sees it: its provider, model and base URL, nothing else."""
    shown = {"provider": str(entry.get("provider") or ""), "model": str(entry.get("model") or "")}
    base = str(entry.get("base_url") or "").strip()
    if base:
        shown["base_url"] = base
    return shown


def fallbacks() -> list[dict]:
    return [_shown(e) for e in _chain(_raw_config())]


def load(body: dict) -> dict:
    # (Scrubbed here, section by section: the env rows are keyed by the variables' own names,
    # OPENROUTER_API_KEY and the like, and hold only previews.)
    return {
        "options": scrub(options(bool(body.get("refresh")))),
        "env": env_rows(),
        "endpoints": scrub(endpoints()),
        "auxiliary": scrub(auxiliary()),
        "fallback_providers": fallbacks(),
        "plugin_version": plugin_version(),
    }


# --- the main model and helpers ------------------------------------------------------------

def lift_key(provider: str) -> bool:
    """An older endpoint's key written into config.yaml itself (`providers.<id>.api_key`, a value,
    not a `${VAR}`) moved to .env behind key_env, as Hermes's own endpoint save migrates one
    (#69449), before the main model is pointed at it: else Hermes copies the value onto
    `model.api_key`, a second plaintext copy in config.yaml. True when one was moved."""
    provider = str(provider or "").strip()
    if not provider:
        return False
    try:
        from hermes_cli.config import (coerce_provider_id, custom_endpoint_key_env, find_provider_entry, load_config,
                                       read_raw_config, save_config, save_env_value)
    except ImportError:
        return False
    with _LOCK:
        raw = read_raw_config()
        providers = raw.get("providers") if isinstance(raw, dict) else None
        stored = entry = None
        for spelling in (provider, provider.removeprefix("custom:")):
            stored, entry = find_provider_entry(providers, spelling)
            if isinstance(entry, dict):
                break
        if not isinstance(entry, dict) or entry.get("key_env"):
            return False
        value = entry.get("api_key")
        if not isinstance(value, str) or not value.strip() or "${" in value:
            return False
        env_var = custom_endpoint_key_env(coerce_provider_id(stored))
        save_env_value(env_var, value.strip())
        cfg = load_config()
        live = (cfg.get("providers") or {}).get(stored)
        if not isinstance(live, dict):
            return False
        live["key_env"] = env_var
        live.pop("api_key", None)
        save_config(cfg)
        return True


def _no_key(body: dict) -> None:
    if str(body.get("api_key") or "").strip():
        raise Refusal(400, "A key isn't taken here (it would be written into config.yaml): set it with set_key or save_endpoint.")


def set_main(body: dict) -> dict:
    """POST /api/model/set, scope main."""
    _no_key(body)
    provider, model = str(body.get("provider") or "").strip(), str(body.get("model") or "").strip()
    base_url = str(body.get("base_url") or "").strip()
    load_config = _need("hermes_cli.config", "load_config", what="load_config")
    apply = _need("hermes_cli.web_server_config", "_apply_model_assignment_sync", what="model assignment")
    if model and not body.get("confirm_expensive_model"):
        try:
            from hermes_cli.model_selection_guards import combined_selection_warning
            warning = combined_selection_warning(model, provider=provider, base_url=base_url)
        except Exception:
            warning = None
        if warning is not None:
            return {"ok": False, "scope": "main", "provider": provider, "model": model,
                    "confirm_required": True, "confirm_message": str(getattr(warning, "message", "") or warning)}
    try:
        from hermes_cli.web_server_config import _prepare_main_assignment
    except ImportError:
        _prepare_main_assignment = None
    lift_key(provider)
    # (The checks reach catalogs and endpoints: before the lock, as the Dashboard does.)
    prepared = _prepare_main_assignment(load_config(), provider, model, base_url, "") if _prepare_main_assignment else None
    with _LOCK:
        if prepared is not None:
            return apply("main", provider, model, "", base_url, "", prepared=prepared)
        return apply("main", provider, model, "", base_url, "")


def set_helper(body: dict) -> dict:
    """POST /api/model/set, scope auxiliary: task "" = every slot, "__reset__" = all back to auto."""
    _no_key(body)
    apply = _need("hermes_cli.web_server_config", "_apply_model_assignment_sync", "_UNSET", what="model assignment")
    apply, unset = apply
    task = str(body.get("task") or "").strip().lower()
    provider, model = str(body.get("provider") or "").strip(), str(body.get("model") or "").strip()
    base_url = str(body.get("base_url") or "").strip()
    effort = body.get("reasoning_effort") if "reasoning_effort" in body else unset
    with _LOCK:
        return apply("auxiliary", provider, model, task, base_url, "", reasoning_effort=effort)


def set_fallbacks(body: dict) -> dict:
    """The chain replaced whole (as PUT /api/config with fallback_providers), each entry keeping
    what it had on disk beyond the three fields; the legacy fallback_model taken out, as `hermes
    fallback` does, so the list is the one source."""
    asked = body.get("fallback_providers")
    if not isinstance(asked, list):
        raise Refusal(400, "fallback_providers must be a list")
    strict, merge, save = _need("hermes_cli.config", "require_readable_config_before_write", "_deep_merge", "save_config",
                                what="config writes")
    with _LOCK:
        existing = strict()
        existing = existing if isinstance(existing, dict) else {}
        known = {}
        for entry in _chain(existing):
            known.setdefault((entry["provider"].lower(), entry["model"].lower()), entry)
        chain, seen = [], set()
        for item in asked:
            if not isinstance(item, dict):
                continue
            provider, model = str(item.get("provider") or "").strip(), str(item.get("model") or "").strip()
            if not provider or not model:
                continue
            entry = dict(known.get((provider.lower(), model.lower()), {}))
            entry.update(provider=provider, model=model)
            if "base_url" in item:
                base = str(item.get("base_url") or "").strip()
                if base:
                    entry["base_url"] = base
                else:
                    entry.pop("base_url", None)
            identity = (provider.lower(), model.lower(), str(entry.get("base_url") or "").rstrip("/").lower())
            if identity in seen:
                continue
            seen.add(identity)
            chain.append(entry)
        merged = merge(existing, {"fallback_providers": chain})
        merged.pop("fallback_model", None)
        save(merged)
    return {"ok": True, "fallback_providers": [_shown(e) for e in chain]}


# --- custom endpoints ----------------------------------------------------------------------

def _config_env():
    try:
        import hermes_cli.web_routers.config_env as config_env
    except ImportError:
        raise Missing("custom endpoints") from None
    return config_env


def save_endpoint(body: dict) -> dict:
    """POST /api/providers/custom-endpoints: the key to .env behind key_env; no api_key keeps the
    old one, "" clears it."""
    config_env = _config_env()
    update = _need("hermes_cli.web_models", "CustomEndpointUpdate", what="custom endpoints")
    load_config, save_config = _need("hermes_cli.config", "load_config", "save_config", what="config writes")
    fields = {"id": str(body.get("id") or ""), "name": str(body.get("name") or ""),
              "base_url": str(body.get("base_url") or ""), "model": str(body.get("model") or ""),
              "make_default": bool(body.get("make_default"))}
    if "api_key" in body and body.get("api_key") is not None:
        fields["api_key"] = str(body.get("api_key"))
    if "api_mode" in body and body.get("api_mode") is not None:
        fields["api_mode"] = str(body.get("api_mode"))
    if body.get("context_length") is not None:
        fields["context_length"] = body.get("context_length")
    if isinstance(body.get("models"), list):
        fields["models"] = [str(m) for m in body["models"] if str(m).strip()]
    if isinstance(body.get("model_details"), list):
        fields["model_details"] = [d for d in body["model_details"] if isinstance(d, dict)]
    try:
        request = update(**fields)
    except Exception as error:  # (pydantic's ValidationError: a bad api_mode or context_length)
        names = ", ".join(sorted({str((e.get("loc") or ["?"])[0]) for e in getattr(error, "errors", lambda: [])()})) or "the endpoint"
        raise Refusal(400, f"Invalid {names}") from None
    try:
        write, response = config_env._write_custom_endpoint, config_env._custom_endpoint_response
    except AttributeError:
        raise Missing("custom endpoints") from None
    with _LOCK:
        cfg = load_config()
        endpoint_id, _entry = write(cfg, request)
        save_config(cfg)
        answer = response(cfg)
    answer["ok"] = True
    answer["id"] = endpoint_id
    return answer


def _endpoint_id(body: dict) -> str:
    endpoint_id = str(body.get("id") or "").strip()
    if not endpoint_id:
        raise Refusal(400, "id is required")
    return endpoint_id


def delete_endpoint(body: dict) -> dict:
    """DELETE /api/providers/custom-endpoints/{id}, but never the main model's own endpoint (Hermes
    would leave the main model with no provider)."""
    endpoint_id = _endpoint_id(body)
    c = _config_env()
    try:
        resolve, legacy_slug, pop_legacy = c._resolve_custom_endpoint_entry, c._custom_endpoint_id, c._pop_legacy_custom_provider
        detach, names_provider, response = c._detach_main_model_from_provider, c._model_names_provider, c._custom_endpoint_response
        coerce, key_env = c.coerce_provider_id, c.custom_endpoint_key_env
    except AttributeError:
        raise Missing("custom endpoints") from None
    load_config, save_config, remove_env_value = _need("hermes_cli.config", "load_config", "save_config", "remove_env_value",
                                                       what="config writes")
    with _LOCK:
        cfg = load_config()
        rows = {row.get("id"): row for row in response(cfg).get("endpoints") or []}
        model_cfg = cfg.get("model") if isinstance(cfg.get("model"), dict) else {}
        providers = cfg.get("providers")
        stored_key, entry = resolve(providers, endpoint_id)
        in_use = bool((rows.get(endpoint_id) or {}).get("is_current"))
        if entry is not None and isinstance(providers, dict):
            in_use = in_use or names_provider(model_cfg, coerce(stored_key), entry)
        if in_use:
            raise Refusal(409, "That endpoint is the main model's: choose another main model before removing it.")
        if entry is not None and isinstance(providers, dict):
            provider_key = coerce(stored_key)
            providers.pop(stored_key, None)
            cfg["providers"] = providers
        else:
            provider_key = legacy_slug(endpoint_id)
            if pop_legacy(cfg, provider_key) is None:
                raise Refusal(404, "custom endpoint not found")
        detach(cfg, provider_key, entry)
        remove_env_value(key_env(provider_key))
        save_config(cfg)
        answer = response(cfg)
    answer["ok"] = True
    return answer


def activate_endpoint(body: dict) -> dict:
    """POST /api/providers/custom-endpoints/{id}/activate: the endpoint becomes the main model."""
    endpoint_id = _endpoint_id(body)
    c = _config_env()
    try:
        resolve, legacy_slug, pop_legacy = c._resolve_custom_endpoint_entry, c._custom_endpoint_id, c._pop_legacy_custom_provider
        to_provider, models_of = c._custom_provider_entry_to_provider_config, c._models_from_custom_endpoint_entry
        validated, assign, raw_key = c._validated_main_model_selection, c._apply_main_model_assignment, c._raw_provider_api_key
        coerce, key_env = c.coerce_provider_id, c.custom_endpoint_key_env
    except AttributeError:
        raise Missing("custom endpoints") from None
    load_config, save_config, save_env_value = _need("hermes_cli.config", "load_config", "save_config", "save_env_value",
                                                     what="config writes")
    with _LOCK:
        cfg = load_config()
        stored_key, entry = resolve(cfg.get("providers"), endpoint_id)
        if entry is None:
            provider_key = legacy_slug(endpoint_id)
            legacy = pop_legacy(cfg, provider_key)
            entry = to_provider(legacy, provider_key=provider_key) if legacy else None
            if entry is None:
                raise Refusal(404, "custom endpoint not found")
            providers = cfg.get("providers") if isinstance(cfg.get("providers"), dict) else {}
            providers[provider_key] = entry
            cfg["providers"] = providers
        else:
            provider_key = coerce(stored_key)
        models = models_of(entry)
        model = str(entry.get("model") or entry.get("default_model") or (models[0] if models else "")).strip()
        base_url = str(entry.get("base_url") or entry.get("api") or "").strip()
        if not model or not base_url:
            raise Refusal(400, "custom endpoint is incomplete")
        model_cfg = assign(cfg.get("model", {}), validated(cfg, provider_key, model, base_url))
        template = ""
        if not entry.get("key_env") and entry.get("api_key"):
            # An older entry's key in config.yaml itself. A `${VAR}` is copied as that template, as
            # the Dashboard does; a value goes to .env behind key_env first (as Hermes's endpoint
            # save migrates one), where the Dashboard would copy it onto model.api_key, a second
            # plaintext copy.
            try:
                template = str(raw_key(provider_key) or "").strip()
            except Exception:
                template = ""
            if not (template.startswith("${") and template.endswith("}")):
                template = ""
                env_var = key_env(provider_key)
                save_env_value(env_var, str(entry["api_key"]).strip())
                entry["key_env"] = env_var
                entry.pop("api_key", None)
                providers = cfg.get("providers") if isinstance(cfg.get("providers"), dict) else {}
                providers[stored_key if stored_key is not None else provider_key] = entry
                cfg["providers"] = providers
        if entry.get("key_env"):
            model_cfg["key_env"] = entry["key_env"]
            model_cfg.pop("api_key", None)
        elif template:
            model_cfg["api_key"] = template
        cfg["model"] = model_cfg
        save_config(cfg)
    return {"ok": True, "provider": provider_key, "model": model}


async def test_endpoint(body: dict) -> dict:
    """POST /api/providers/custom-endpoints/validate: asks the endpoint for its models. Writes
    nothing."""
    c = _config_env()
    update = _need("hermes_cli.web_models", "CustomEndpointUpdate", what="custom endpoints")
    validate = getattr(c, "validate_custom_endpoint", None)
    if validate is None:
        raise Missing("endpoint tests")
    fields = {"name": "", "base_url": str(body.get("base_url") or ""), "model": str(body.get("model") or "")}
    if body.get("api_key"):
        fields["api_key"] = str(body.get("api_key"))
    if body.get("api_mode") is not None:
        fields["api_mode"] = str(body.get("api_mode"))
    try:
        request = update(**fields)
    except Exception:
        raise Refusal(400, "Invalid api_mode") from None
    answer = await validate(request)
    answer = dict(answer or {})
    answer.setdefault("models", [])
    answer.setdefault("model_details", [])
    answer.setdefault("resolved_base_url", str(body.get("base_url") or "").strip().rstrip("/"))
    return answer


ACTIONS = {
    "load": load, "set_key": set_key, "remove_key": remove_key, "set_main": set_main, "set_helper": set_helper,
    "set_fallbacks": set_fallbacks, "save_endpoint": save_endpoint, "delete_endpoint": delete_endpoint,
    "activate_endpoint": activate_endpoint,
}


def run(api, body: dict) -> dict:
    """One action, in the profile's scope: what to answer (a Refusal for anything but a 200)."""
    action = str(body.get("action") or "").strip()
    if action not in ACTIONS:
        raise Refusal(400, f"Unknown action {action or '(none)'}." if action else "action is required")
    name = profile_name(body.get("profile"))
    with scoped(api, name):
        return ACTIONS[action](body)


def wire() -> object:
    """A factory for `ctx.register_platform_handler("api_server", …)`, as work_runs.py's."""
    def factory(app, api) -> None:
        if app is None or not hasattr(app, "router"):
            return
        from aiohttp import web

        def failed(status: int, message: str):
            return web.json_response({"error": {"message": message}}, status=status)

        async def handle(request):
            denied = api._check_auth(request)
            if denied is not None:
                return denied
            try:
                body = await request.json()
            except Exception:
                body = None
            if not isinstance(body, dict):
                return failed(400, "A JSON object is required.")
            action = str(body.get("action") or "").strip()
            try:
                if action == "test_endpoint":
                    profile_name(body.get("profile"))  # (an unknown one is still a 404)
                    answer = await test_endpoint(body)
                else:
                    answer = await asyncio.to_thread(run, api, body)
            except Refusal as refusal:
                return failed(refusal.status, refusal.message)
            except ValueError as error:  # Hermes's .env writers refuse a name or a locked key so
                return failed(400, str(error))
            except Exception as error:
                hermes = _http_error(error)
                if hermes is not None:
                    return failed(hermes.status, hermes.message)
                # (Never the body or a value: the action and what went wrong, by kind.)
                log.debug("redde-push: models %s failed (%s)", action or "?", type(error).__name__)
                return failed(500, f"{action or 'That'} failed on this Hermes ({type(error).__name__}).")
            return web.json_response(answer if action == "load" else scrub(answer))

        app.router.add_route("POST", ROUTE, handle)

    # Hermes wires a plugin's factories once each, known by their qualified name: work_runs.py's is
    # `wire.<locals>.factory` too, and this one would be taken for it and skipped.
    factory.__qualname__ = factory.__name__ = "models_route_factory"
    return factory
