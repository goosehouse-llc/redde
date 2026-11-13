#!/bin/sh
# Installs the Redde bridge on this computer (a Mac, or Linux with systemd) and runs it as a
# service that starts with the computer. Run again to update. Then shows how to set Redde up.
#
#   curl -fsSL https://raw.githubusercontent.com/goosehouse-llc/redde/main/companion/redde-bridge/install.sh | sh
#
# Options go after `sh -s --`, for example the name your phone reaches this computer by:
#
#   curl -fsSL …/install.sh | sh -s -- --host studio.example.ts.net
#
# It downloads four Python files into a temporary folder and runs `redde_bridge.py --install`,
# which copies them to ~/.local/share/redde-bridge. Standard library only: Python 3.9 or later.
set -eu

BASE="${REDDE_BRIDGE_BASE:-https://raw.githubusercontent.com/goosehouse-llc/redde/main/companion/redde-bridge}"

# The newest Python 3 that is 3.9 or later. A Mac has /usr/bin/python3 once the Command Line Tools
# are installed (`xcode-select --install`).
PYTHON=""
for candidate in python3.14 python3.13 python3.12 python3.11 python3.10 python3 /usr/bin/python3; do
  if command -v "$candidate" >/dev/null 2>&1 &&
     "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
    PYTHON="$(command -v "$candidate")"
    break
  fi
done
if [ -z "$PYTHON" ]; then
  echo "The Redde bridge needs Python 3.9 or later." >&2
  case "$(uname -s)" in
    Darwin) echo "On a Mac: xcode-select --install (or brew install python), then run this again." >&2 ;;
    *) echo "Install python3 with your package manager, then run this again." >&2 ;;
  esac
  exit 1
fi

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
for file in redde_bridge.py redde_push.py redde_qr.py redde_codex.py; do
  curl -fsSL "$BASE/$file" -o "$DIR/$file"
done
"$PYTHON" "$DIR/redde_bridge.py" --install "$@"
