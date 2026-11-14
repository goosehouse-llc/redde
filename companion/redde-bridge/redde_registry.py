"""Agents from the ACP registry (agentclientprotocol.com/registry), added to the bridge.

The registry lists every agent that speaks ACP and how to run it: an npm package run with npx, a
Python one run with uvx, or a download per platform. Adding one writes its `[agents.<id>]` table to
the config; a download goes in the bridge's folder first, checked against the registry's checksum.

    python3 redde_bridge.py --registry          the agents this computer can run
    python3 redde_bridge.py --add-agent pi-acp  add one (Redde can do this too, from the phone)
"""
from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shutil
import stat
import tarfile
import urllib.request
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

REGISTRY_URL = os.environ.get("REDDE_BRIDGE_REGISTRY", "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")
#: Biggest download the bridge takes for one agent.
MAX_DOWNLOAD = 600 * 1024 * 1024

#: Adapters that run a program of their own, which has to be installed and set up on the computer
#: first: the registry doesn't say so. id → (program, how to install it).
NEEDS = {
    "pi-acp": ("pi", "npm install -g @earendil-works/pi-coding-agent"),
    "openclaw": ("openclaw", "npm install -g openclaw@latest"),
    "claude-acp": ("claude", "npm install -g @anthropic-ai/claude-code"),
}
#: Agents that speak ACP but aren't in the registry, offered beside it. "local" runs a program
#: that's installed on the computer.
EXTRAS = [
    # OpenClaw's own ACP bridge, to the Gateway in its config (`gateway.remote.url` for one
    # elsewhere): docs.openclaw.ai/cli/acp.
    {"id": "openclaw", "name": "OpenClaw", "version": "", "license": "MIT", "website": "https://docs.openclaw.ai/cli/acp",
     "description": "Your OpenClaw agent, through its Gateway",
     "distribution": {"local": {"cmd": "openclaw", "args": ["acp"]}}},
]
#: Nicer names than the registry's, where it names the adapter rather than the agent.
NAMES = {"pi-acp": "Pi", "claude-acp": "Claude Code", "goose": "Goose"}


class RegistryError(Exception):
    pass


def _open(url: str, timeout: float):
    """The registry's CDN turns away Python's own user agent."""
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "redde-bridge (+https://redde.goosehouse.org)"}),
                                  timeout=timeout)


@dataclass
class Entry:
    """One agent in the registry, as this computer would run it."""
    id: str
    name: str
    version: str
    description: str = ""
    license: str = ""
    website: str = ""
    #: "npx", "uvx" or "binary"; "" when it has nothing for this computer.
    kind: str = ""
    #: The command, for npx and uvx; a binary's is known once it's downloaded.
    command: list[str] = field(default_factory=list)
    env: dict[str, str] = field(default_factory=dict)
    archive: str = ""
    sha256: str = ""
    binary_cmd: str = ""
    binary_args: list[str] = field(default_factory=list)

    @property
    def bridge_id(self) -> str:
        """Its id on the bridge: the registry's without "-acp" ("pi-acp" → "pi")."""
        ident = re.sub(r"-acp$", "", self.id) or self.id
        return re.sub(r"[^a-z0-9_-]", "-", ident.lower())

    @property
    def needs(self) -> tuple[str, str] | None:
        return NEEDS.get(self.id)

    def summary(self, installed: set[str]) -> dict:
        """For `_redde/registry` and `--registry`."""
        needs = self.needs
        return {"id": self.id, "bridgeId": self.bridge_id, "name": self.name, "version": self.version,
                "description": self.description, "license": self.license, "website": self.website,
                "kind": self.kind, "runs": self.shown_command(),
                "installed": self.bridge_id in installed or self.id in installed,
                "needs": {"program": needs[0], "install": needs[1], "found": shutil.which(needs[0]) is not None} if needs else None}

    def shown_command(self) -> str:
        if self.kind == "binary":
            return f"{self.binary_cmd.lstrip('./')} {' '.join(self.binary_args)}".strip() + f" (downloaded from {_host(self.archive)})"
        return " ".join(self.command)


def _host(url: str) -> str:
    return re.sub(r"^https?://([^/]+).*$", r"\1", url)


def platform_key() -> str:
    """The registry's name for this computer: darwin-aarch64, linux-x86_64…"""
    system = {"darwin": "darwin", "linux": "linux", "windows": "windows"}.get(platform.system().lower(), platform.system().lower())
    machine = platform.machine().lower()
    machine = {"arm64": "aarch64", "amd64": "x86_64"}.get(machine, machine)
    return f"{system}-{machine}"


def parse(raw: dict, here: str | None = None) -> list[Entry]:
    """The registry's agents, each with how this computer runs it (npx first, then uvx, then a download)."""
    here = here or platform_key()
    entries = []
    listed = [a for a in raw.get("agents") or [] if isinstance(a, dict)]
    known = {a.get("id") for a in listed}
    for agent in listed + [e for e in EXTRAS if e["id"] not in known]:
        if not isinstance(agent, dict) or not agent.get("id"):
            continue
        entry = Entry(id=str(agent["id"]), name=NAMES.get(agent["id"], str(agent.get("name") or agent["id"])),
                      version=str(agent.get("version") or ""), description=str(agent.get("description") or ""),
                      license=str(agent.get("license") or ""),
                      website=str(agent.get("website") or agent.get("repository") or ""))
        dist = agent.get("distribution") or {}
        if isinstance(dist.get("local"), dict) and dist["local"].get("cmd"):
            entry.kind = "local"
            entry.command = [str(dist["local"]["cmd"])] + [str(a) for a in dist["local"].get("args") or []]
        elif isinstance(dist.get("npx"), dict) and dist["npx"].get("package") and shutil.which("npx"):
            entry.kind = "npx"
            entry.command = ["npx", "-y", str(dist["npx"]["package"])] + [str(a) for a in dist["npx"].get("args") or []]
            entry.env = {str(k): str(v) for k, v in (dist["npx"].get("env") or {}).items()}
        elif isinstance(dist.get("uvx"), dict) and dist["uvx"].get("package") and shutil.which("uvx"):
            entry.kind = "uvx"
            entry.command = ["uvx", str(dist["uvx"]["package"])] + [str(a) for a in dist["uvx"].get("args") or []]
            entry.env = {str(k): str(v) for k, v in (dist["uvx"].get("env") or {}).items()}
        elif isinstance((dist.get("binary") or {}).get(here), dict):
            binary = dist["binary"][here]
            if binary.get("archive") and binary.get("cmd"):
                entry.kind = "binary"
                entry.archive = str(binary["archive"])
                entry.sha256 = str(binary.get("sha256") or "").lower()
                entry.binary_cmd = str(binary["cmd"])
                entry.binary_args = [str(a) for a in binary.get("args") or []]
                entry.env = {str(k): str(v) for k, v in (binary.get("env") or {}).items()}
        entries.append(entry)
    return entries


def fetch(url: str = REGISTRY_URL, timeout: float = 20) -> list[Entry]:
    try:
        with _open(url, timeout) as reply:
            raw = json.loads(reply.read(8 * 1024 * 1024))
    except (OSError, ValueError) as error:
        raise RegistryError(f"Couldn't read the ACP registry: {error}") from None
    return parse(raw)


def installed_ids(agents: list) -> set[str]:
    """The registry agents the bridge has: by id, and by the package or program its command runs
    (a Claude Code added by hand is the registry's claude-acp)."""
    found: set[str] = set()
    for agent in agents:
        found.add(agent.id)
        words = " ".join(agent.command)
        if "claude-agent-acp" in words:
            found.add("claude-acp")
        if "codex-acp" in words:
            found.add("codex-acp")
        if "pi-acp" in words:
            found.add("pi-acp")
        program = Path(agent.command[0]).name if agent.command else ""
        if program == "agy":
            found.add("antigravity-acp")
        if program == "gemini" or "@google/gemini-cli" in words:
            found.add("gemini")
        if program in ("goose", "opencode", "cursor-agent", "copilot", "kiro-cli", "openclaw"):
            found.add({"cursor-agent": "cursor", "copilot": "github-copilot-cli", "kiro-cli": "kiro"}.get(program, program))
    return found


# MARK: - Downloads

def download(entry: Entry, folder: Path, timeout: float = 60) -> list[str]:
    """Fetches a binary agent into `folder/<id>/<version>`, checks it against the registry's
    checksum, and returns its command. Kept when it's there already."""
    target = folder / entry.bridge_id / re.sub(r"[^0-9A-Za-z._-]", "_", entry.version or "latest")
    program = (target / entry.binary_cmd).resolve()
    if not str(program).startswith(str(target.resolve()) + os.sep):
        raise RegistryError(f"{entry.name}'s command is outside its folder")
    if program.exists():
        return [str(program)] + entry.binary_args
    if not entry.archive.startswith("https://"):
        raise RegistryError(f"{entry.name} isn't offered over https")
    staging = target.with_name(target.name + ".part")
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    try:
        name = entry.archive.rsplit("/", 1)[-1].split("?")[0] or "download"
        archive = staging / name
        digest = hashlib.sha256()
        size = 0
        try:
            with _open(entry.archive, timeout) as reply, archive.open("wb") as out:
                while chunk := reply.read(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_DOWNLOAD:
                        raise RegistryError(f"{entry.name}'s download is too big")
                    digest.update(chunk)
                    out.write(chunk)
        except OSError as error:
            raise RegistryError(f"Couldn't download {entry.name}: {error}") from None
        if entry.sha256 and digest.hexdigest() != entry.sha256:
            raise RegistryError(f"{entry.name}'s download doesn't match the registry's checksum")
        unpack(archive, staging)
        archive.unlink(missing_ok=True)
        unpacked = staging / entry.binary_cmd
        if not unpacked.is_file():
            raise RegistryError(f"{entry.name}'s download has no {entry.binary_cmd}")
        unpacked.chmod(unpacked.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        shutil.rmtree(target, ignore_errors=True)
        os.replace(staging, target)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    return [str(program)] + entry.binary_args


def unpack(archive: Path, into: Path) -> None:
    """A zip or tarball, nothing outside `into`; a single file is the program itself."""
    root = into.resolve()

    def inside(name: str) -> Path:
        path = (into / name).resolve()
        if path != root and not str(path).startswith(str(root) + os.sep):
            raise RegistryError(f"The download has a file outside its folder: {name}")
        return path

    lower = archive.name.lower()
    if lower.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            for info in z.infolist():
                path = inside(info.filename)
                if info.is_dir():
                    path.mkdir(parents=True, exist_ok=True)
                    continue
                path.parent.mkdir(parents=True, exist_ok=True)
                with z.open(info) as src, path.open("wb") as out:
                    shutil.copyfileobj(src, out)
                mode = (info.external_attr >> 16) & 0o777
                if mode:
                    path.chmod(mode)
    elif re.search(r"\.(tar|tar\.gz|tgz|tar\.bz2|tbz2|tar\.xz|txz)$", lower):
        with tarfile.open(archive) as t:
            for member in t.getmembers():
                inside(member.name)
                if member.issym() or member.islnk():
                    inside(os.path.join(os.path.dirname(member.name), member.linkname))
            if hasattr(tarfile, "data_filter"):   # Python 3.12+, and 3.9+ security releases
                t.extractall(into, filter="data")
            else:
                t.extractall(into)
    # Anything else is the program as it is (cmd names it).


# MARK: - The config

def note(entry: Entry) -> str:
    """The comment over an added agent's table, which removing it takes too."""
    if entry.kind == "local":
        return f"Added by the Redde bridge ({entry.id}, not in the ACP registry)."
    return f"Added from the ACP registry ({entry.id} {entry.version})."


def table(ident: str, name: str, command: list[str], cwd: str, env: dict[str, str], note: str) -> str:
    lines = ["", f"# {note}", f"[agents.{ident}]", f"name = {json.dumps(name)}", f"command = {json.dumps(command)}",
             f"cwd = {json.dumps(cwd)}"]
    if env:
        lines.append("env = { " + ", ".join(f"{json.dumps(k)} = {json.dumps(v)}" for k, v in env.items()) + " }")
    return "\n".join(lines) + "\n"


def add_to_config(path: Path, ident: str, text: str) -> None:
    current = path.read_text()
    if re.search(rf"^\s*\[agents\.{re.escape(ident)}\]\s*$", current, re.M):
        raise RegistryError(f"The bridge has an agent called {ident} already")
    path.write_text(current.rstrip("\n") + "\n" + text)


def remove_from_config(path: Path, ident: str) -> bool:
    """Takes `[agents.<ident>]` out, with the note above it that adding put there. True when it was there."""
    lines = path.read_text().split("\n")
    start = next((i for i, l in enumerate(lines) if l.strip() == f"[agents.{ident}]"), None)
    if start is None:
        return False
    end = next((i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith("[")), len(lines))
    # The trailing comments and blank lines belong to the next table.
    while end > start + 1 and (not lines[end - 1].strip() or lines[end - 1].lstrip().startswith("#")):
        end -= 1
    if start > 0 and lines[start - 1].startswith(("# Added from the ACP registry", "# Added by the Redde bridge")):
        start -= 1
    if start > 0 and not lines[start - 1].strip():
        start -= 1
    path.write_text("\n".join(lines[:start] + lines[end:]))
    return True
