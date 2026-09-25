#!/bin/zsh
# Builds Redde Calendar MCP, wraps it in a signed app (so macOS can grant Calendar access), and
# runs it at login with launchd.
#
#   ./install.sh                 read-only (default)
#   ./install.sh --allow-writes  also offer create_event
#   ./install.sh --uninstall
#
# Set SIGN_IDENTITY to a codesigning identity (name or SHA-1). A stable identity keeps the Calendar
# permission across rebuilds; ad hoc signing ("-") works but macOS may ask again after each build.
set -euo pipefail
cd "${0:A:h}"

LABEL="com.goosehouse.redde-calendar-mcp"
APP="$HOME/Applications/Redde Calendar MCP.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/redde-calendar-mcp.log"
PORT="${PORT:-8765}"
DOMAIN="gui/$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$AGENT"; rm -rf "$APP"
  echo "Removed. The token is kept in ~/Library/Application Support/Redde Calendar MCP."
  exit 0
fi

EXTRA_ARGS=()
[[ "${1:-}" == "--allow-writes" ]] && EXTRA_ARGS=(--allow-writes)

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ReddeCalendarMCP"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$BIN" "$APP/Contents/MacOS/redde-calendar-mcp"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>Redde Calendar MCP</string>
  <key>CFBundleDisplayName</key><string>Redde Calendar MCP</string>
  <key>CFBundleExecutable</key><string>redde-calendar-mcp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Lets your Redde agent read your calendar when you ask about your schedule.</string>
  <key>NSCalendarsUsageDescription</key><string>Lets your Redde agent read your calendar when you ask about your schedule.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Lets your Redde agent read and add reminders when you ask.</string>
  <key>NSRemindersUsageDescription</key><string>Lets your Redde agent read and add reminders when you ask.</string>
</dict></plist>
PLIST
codesign --force --sign "$SIGN_IDENTITY" --identifier "$LABEL" "$APP"

ARGS_XML=""
for a in --port "$PORT" "${EXTRA_ARGS[@]}"; do ARGS_XML+="    <string>$a</string>"$'\n'; done
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$APP/Contents/MacOS/redde-calendar-mcp</string>
$ARGS_XML  </array>
  <key>AssociatedBundleIdentifiers</key><string>$LABEL</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLIST
launchctl bootstrap "$DOMAIN" "$AGENT"

echo "Installed and running on port $PORT (signed with: $SIGN_IDENTITY)."
echo "If macOS asks, allow Calendar access for Redde Calendar MCP."
echo "Log: $LOG"
echo "Token: $APP/Contents/MacOS/redde-calendar-mcp --print-token"
