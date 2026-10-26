"""Plugins (lab.sh plugins), over the Dashboard socket, as Redde's Plugins screen uses `plugins.manage`:

  list      the installed plugins are listed, each with where it came from and whether it is on.
  install   a catalog plugin by its name alone (accent-picker: Nous Research's own, no key, no server,
            any Hermes), fetched by Hermes at the commit its catalog pins: installed and on, its row
            naming the catalog entry and its tier (0.21.3 and later; 0.21.0 installs from git only).
  bot       installed for the main profile, a bot hasn't got it; installed for the bot, it has.
  toggle    off, and on again.
  remove    gone from the list (0.21.5 and later).

Needs the network: Hermes reads the catalog from Nous Research's site and clones from GitHub.
Run against a lab that is up with the approval scenario, in a home of its own.
"""
import asyncio
import json

import check
from check import Dashboard, report

PLUGIN = "accent-picker"
BOT = "tinker"


def release():
    import hermes_cli
    parts = tuple(int(p) for p in str(getattr(hermes_cli, "__version__", "0.0.0")).split(".")[:3] if p.isdigit())
    return (99, 0, 0) if parts in ((), (0, 0, 0)) else parts


async def listed(dash, profile=None):
    params = {"action": "list", **({"profile": profile} if profile else {})}
    return (await dash.call("plugins.manage", params)).get("plugins") or []


def row(rows, name=PLUGIN):
    return next((r for r in rows if r.get("catalog_name") == name or r.get("name") == name), None)


async def main():
    dash = await Dashboard.connect()
    rows = await listed(dash)
    print(f"  info  installed at the start: {[(r.get('name'), r.get('source'), r.get('status')) for r in rows]}")
    report(all("name" in r and "status" in r and "source" in r for r in rows), "the installed plugins are listed, with where from and whether on",
           json.dumps(rows)[:300])
    if release() < (0, 21, 3):
        print("  info  this release installs from git only, not from the catalog by name")
        return
    # Made first: a new bot is a copy of the main profile, its plugins included.
    await dash.call("profiles.create", {"name": BOT, "clone_from": "default", "no_alias": True, "share_auth": True,
                                        "description": "Tinkers.", "soul": "You are Tinker."})

    result = await dash.call("plugins.manage", {"action": "install", "catalog_name": PLUGIN, "enable": True})
    print(f"  info  install: {json.dumps(result)[:400]}")
    installed = row(await listed(dash))
    report(bool(result.get("ok")) and installed is not None and installed.get("status") == "enabled",
           "a catalog plugin installed by name, and on", json.dumps(installed)[:300])
    report(installed is not None and installed.get("catalog_name") == PLUGIN and installed.get("catalog_tier") == "official",
           "its row names its catalog entry and tier", json.dumps(installed)[:300])

    report(row(await listed(dash, BOT)) is None, "installed for the main profile, the bot hasn't got it")
    got = await dash.call("plugins.manage", {"action": "install", "catalog_name": PLUGIN, "enable": True, "profile": BOT})
    bots = row(await listed(dash, BOT))
    report(bool(got.get("ok")) and bots is not None and bots.get("status") == "enabled", "installed for a bot too, on", json.dumps(bots)[:200])

    key = (bots or {}).get("key") or PLUGIN
    await dash.call("plugins.manage", {"action": "toggle", "key": key, "enable": False, "profile": BOT})
    off = row(await listed(dash, BOT))
    await dash.call("plugins.manage", {"action": "toggle", "key": key, "enable": True, "profile": BOT})
    on = row(await listed(dash, BOT))
    report((off or {}).get("status") != "enabled" and (on or {}).get("status") == "enabled", "switched off, and on again",
           f"{(off or {}).get('status')} → {(on or {}).get('status')}")

    if release() >= (0, 21, 5):
        await dash.call("plugins.manage", {"action": "remove", "name": (bots or {}).get("name") or PLUGIN, "profile": BOT})
        report(row(await listed(dash, BOT)) is None, "removed, and gone from the list")
    else:
        print("  info  this release has no remove")


asyncio.run(main())
raise SystemExit(1 if check.failures else 0)
