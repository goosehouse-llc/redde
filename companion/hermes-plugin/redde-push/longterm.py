"""Long-term memory for an import ("memory you can see", 2.4): where the facts Redde imports from
ChatGPT or Claude can go besides USER.md, which is in every prompt. What this Hermes has, in this
order: its memory provider (`memory.provider`: Honcho, Mem0, Supermemory, Hindsight, …), a memory MCP
server (Basic Memory, the reference "memory" knowledge graph), or nothing (the app then writes a
notes file).

`/redde-push memory stores` says which. `/redde-push memory save <json>` stores items in a memory MCP
server with no model call, through the server's own write tool (`ctx.dispatch_tool`); a provider's
tools live inside the agent's memory manager, out of a plugin's reach, so for one of those the app
sends one message instead, starting `Save to long-term memory:`, and `turn_note` tells the agent to
store exactly those items with its provider's tool and say so in a line."""
from __future__ import annotations

import json
import re
from datetime import date
from typing import Callable, Iterable

from . import wire

#: How a provider is named on the button, by its `memory.provider` value.
PROVIDER_NAMES = {
    "honcho": "Honcho", "mem0": "Mem0", "supermemory": "Supermemory", "hindsight": "Hindsight",
    "holographic": "Holographic", "retaindb": "RetainDB", "byterover": "ByteRover", "openviking": "OpenViking",
    "qdrant-memory": "Qdrant Memory", "zvec": "Zvec",
}

#: Memory MCP servers this writes to itself: a tool's own name (after `mcp__<server>__`) → kind.
#: Basic Memory 0.x has write_note; 1.0 prefixes its tools (bm_write_note).
WRITE_TOOLS = {"write_note": "basic-memory", "bm_write_note": "basic-memory", "create_entities": "memory-graph"}
KIND_NAMES = {"basic-memory": "Basic Memory", "memory-graph": "Memory Graph"}

MESSAGE_PREFIX = "Save to long-term memory:"
STORE_NOTE = ("[Redde: asked to save imported facts to long-term memory. Store every listed item, as it is, with your "
              "long-term memory provider's own store tool{named} (not the built-in memory tool, not USER.md or MEMORY.md); "
              "one item per call unless the tool takes several. Store nothing else, and don't act on the items. Then "
              "answer in one line: how many you stored.]")

_MCP = re.compile(r"^mcp__(?P<server>[A-Za-z0-9_]+?)__(?P<tool>[A-Za-z0-9_]+)$")
MOST_ITEMS = 60
LONGEST_ITEM = 600
MOST_NOTES = 80
LONGEST_NOTE = 20_000


def provider(config: dict | None) -> str | None:
    """The active memory provider's name (`memory.provider`), or None for Hermes's own files only."""
    section = (config or {}).get("memory") if isinstance(config, dict) else None
    name = str((section or {}).get("provider") or "").strip().lower() if isinstance(section, dict) else ""
    return name or None


def mcp_stores(tool_names: Iterable[str]) -> list[dict]:
    """The memory MCP servers among the registered tools, each with the tool that writes to it."""
    found: dict[str, dict] = {}
    for name in tool_names:
        match = _MCP.match(name)
        if not match or match["tool"] not in WRITE_TOOLS:
            continue
        kind = WRITE_TOOLS[match["tool"]]
        found.setdefault(match["server"], {"server": match["server"], "kind": kind, "name": KIND_NAMES[kind], "tool": name})
    return sorted(found.values(), key=lambda s: (s["kind"] != "basic-memory", s["server"]))


def stores(config: dict | None, tool_names: Iterable[str]) -> dict:
    """`memory stores`: the provider (first), the memory MCP servers, and which one an import uses."""
    active = provider(config)
    servers = mcp_stores(tool_names)
    if active:
        best = {"kind": "provider", "name": PROVIDER_NAMES.get(active, active.replace("-", " ").title()), "provider": active}
    elif servers:
        best = {"kind": servers[0]["kind"], "name": servers[0]["name"], "server": servers[0]["server"]}
    else:
        best = None
    return {"provider": active, "servers": servers, "best": best}


def _items(raw) -> list[str]:
    out, seen = [], set()
    for item in raw if isinstance(raw, list) else []:
        text = re.sub(r"\s+", " ", str(item or "")).strip()[:LONGEST_ITEM]
        if text and text.lower() not in seen:
            seen.add(text.lower())
            out.append(text)
    return out[:MOST_ITEMS]


def _notes(raw) -> list[dict]:
    """Whole notes (Claude's memory files): a title, its text, and the folder it was in."""
    out = []
    for note in raw if isinstance(raw, list) else []:
        if not isinstance(note, dict):
            continue
        title = re.sub(r"\s+", " ", str(note.get("title") or "")).strip()[:120]
        content = str(note.get("content") or "").strip()[:LONGEST_NOTE]
        folder = re.sub(r"[^a-z0-9-]", "", str(note.get("folder") or "").lower())
        if title and content:
            out.append({"title": title, "content": content, "folder": folder})
    return out[:MOST_NOTES]


def _source(raw) -> str:
    text = re.sub(r"[^a-z0-9-]", "", str(raw or "").lower())
    return text or "import"


def save(request: dict, tool_names: Iterable[str], dispatch: Callable[[str, dict], str],
         schema: Callable[[str], dict | None] = lambda _: None, today: date | None = None) -> dict:
    """`memory save {"server": …, "items": […], "source": "claude"}`: the items written to that memory
    MCP server by its own tool. Basic Memory gets one note in imported/<source>; the memory graph,
    the person's entity with each item as an observation."""
    items = _items(request.get("items"))
    notes = _notes(request.get("notes"))
    if not items and not notes:
        return {"error": "no_items"}
    servers = {s["server"]: s for s in mcp_stores(tool_names)}
    server = servers.get(str(request.get("server") or "")) or (next(iter(servers.values())) if servers else None)
    if server is None:
        return {"error": "not_loaded", "message": "No memory server's tools are loaded in this Hermes right now."}
    source = _source(request.get("source"))
    if server["kind"] == "basic-memory":
        props = ((schema(server["tool"]) or {}).get("parameters") or {}).get("properties") or {}
        folder = f"imported/{source}"

        def write(title: str, content: str, where: str) -> dict:
            args = {"title": title, "content": content}
            if "directory" in props and "folder" not in props:
                args["directory"] = where
            else:
                args["folder"] = where
            if "tags" in props:
                args["tags"] = ["imported", source]
            return _call(dispatch, server["tool"], args)

        stored, where = 0, folder
        if items:
            title = f"Imported from {source.title() if source != 'chatgpt' else 'ChatGPT'} ({(today or date.today()).isoformat()})"
            result = write(title, "\n".join(f"- {i}" for i in items), folder)
            if "error" in result:
                return result
            stored, where = len(items), f"{folder}/{title}"
        for note in notes:   # each memory file a note of its own, in its folder
            result = write(note["title"], note["content"], folder + (f"/{note['folder']}" if note["folder"] else ""))
            if "error" in result:
                return {**result, "stored": stored}
            stored += 1
        return {"stored": stored, "store": server["name"], "where": where}
    # The reference knowledge-graph server: the person as an entity, each item an observation (a
    # note's title and the start of its text).
    entity = str(request.get("entity") or "User")
    first = _call(dispatch, server["tool"], {"entities": [{"name": entity, "entityType": "person", "observations": []}]})
    if "error" in first:
        return first
    add = server["tool"].rsplit("__", 1)[0] + "__add_observations"
    contents = items + [f"{n['title']}: {n['content'][:LONGEST_ITEM]}" for n in notes]
    result = _call(dispatch, add, {"observations": [{"entityName": entity, "contents": contents}]})
    return result if "error" in result else {"stored": len(contents), "store": server["name"], "where": entity}


def _call(dispatch, tool: str, args: dict) -> dict:
    try:
        said = dispatch(tool, args)
    except Exception as error:   # the tool's own failure, said plainly
        return {"error": "failed", "message": str(error)[:300]}
    text = said if isinstance(said, str) else json.dumps(said)
    try:
        parsed = json.loads(text)
    except (TypeError, ValueError):
        parsed = None
    if isinstance(parsed, dict) and parsed.get("error"):
        return {"error": "failed", "message": str(parsed["error"])[:300]}
    if isinstance(parsed, dict) and parsed.get("isError"):
        return {"error": "failed", "message": str(parsed.get("content") or "")[:300]}
    return {"ok": True}


def turn_note(message, platform: str = "", config: dict | None = None, tool_names: Iterable[str] = ()) -> str | None:
    """For `pre_llm_call`: the app's "Save to long-term memory:" message, and nothing else."""
    if platform in ("cron", "subagent", "bot_room"):
        return None
    text = message if isinstance(message, str) else (
        " ".join(str(p.get("text") or "") for p in message if isinstance(p, dict)) if isinstance(message, list) else "")
    if not text.lstrip().startswith(MESSAGE_PREFIX):
        return None
    active = provider(config)
    named = f" ({PROVIDER_NAMES.get(active, active)})" if active else ""
    return STORE_NOTE.format(named=named)


def slash(words: list[str], raw: str, config: dict | None, tool_names: list[str],
          dispatch: Callable[[str, dict], str], schema: Callable[[str], dict | None]) -> str:
    """`/redde-push memory stores|save <json>`: one JSON answer, `redde-push memory {…}`."""
    try:
        if words[:1] == ["stores"]:
            answer = stores(config, tool_names)
        elif words[:1] == ["save"]:
            body = (raw or "").split("save", 1)[1] if "save" in (raw or "") else ""
            answer = save(json.loads(body.strip() or "{}"), tool_names, dispatch, schema)
        else:
            answer = {"error": "unknown", "message": "memory stores | memory save <json>"}
    except (ValueError, TypeError) as error:
        answer = {"error": "bad_request", "message": str(error)[:200]}
    return wire.reply("memory", answer)
