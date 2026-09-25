#!/bin/zsh
# Build Redde for the iOS Simulator with the CarPlay scene switched on, without touching the
# committed config (the iPhone build keeps CarPlay dormant; see README → CarPlay).
#
#   scripts/carplay-simulator.sh [entitlement-key] [simulator-name]
#
# Generates a separate, git-ignored EchoCarPlaySimulator.xcodeproj whose app target adds the CarPlay scene
# manifest and entitlement. The default key is the voice-based conversational category, which
# needs an iOS 26.4+ simulator (Xcode 26.4+). Older simulators only know the original
# categories; pass e.g. com.apple.developer.carplay-maps to preview the screens there.
# Then: Simulator → I/O → External Displays → CarPlay, and tap Redde on the car screen.
set -euo pipefail
cd "${0:A:h}/.."

KEY="${1:-com.apple.developer.carplay-voice-based-conversation}"
SIM="${2:-iPhone 17 Pro Max}"
OUT="DerivedData-carplay"
SPEC=".carplay-simulator.yml"   # must sit next to project.yml so its relative paths resolve
mkdir -p "$OUT"
trap 'rm -f "$SPEC"' EXIT

KEY="$KEY" OUT="$OUT" SPEC="$SPEC" python3 - <<'PY'
import os, yaml
spec = yaml.safe_load(open("project.yml"))
spec["name"] = "EchoCarPlaySimulator"   # separate .xcodeproj next to Echo.xcodeproj (git-ignored)
out, key = os.environ["OUT"], os.environ["KEY"]
app = spec["targets"]["Echo"]
for src in app["sources"]:
    if isinstance(src, dict) and src.get("path") == "Echo":
        src.setdefault("excludes", []).extend(["Info.plist", "Echo.entitlements"])
app["entitlements"]["path"] = f"{out}/overlay/Echo.entitlements"
app["entitlements"]["properties"][key] = True
app["info"]["path"] = f"{out}/overlay/Info.plist"
app["info"]["properties"]["UIApplicationSceneManifest"] = {
    "UIApplicationSupportsMultipleScenes": True,
    "UISceneConfigurations": {"CPTemplateApplicationSceneSessionRoleApplication": [{
        "UISceneClassName": "CPTemplateApplicationScene",
        "UISceneConfigurationName": "CarPlay",
        "UISceneDelegateClassName": "$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate",
    }]},
}
yaml.safe_dump(spec, open(os.environ["SPEC"], "w"), sort_keys=False)
PY

xcodegen generate --quiet --spec "$SPEC"

# Simulator builds aren't provisioned, so Apple's grant isn't needed here.
xcodebuild -project EchoCarPlaySimulator.xcodeproj -scheme Echo \
  -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath "$OUT/build" -quiet build

APP="$OUT/build/Build/Products/Debug-iphonesimulator/Echo.app"
open -a Simulator
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl install "$SIM" "$APP"
echo "Installed with $KEY on $SIM."
echo "Open Simulator → I/O → External Displays → CarPlay, then tap Redde on the car screen."
