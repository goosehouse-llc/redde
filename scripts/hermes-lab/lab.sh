#!/bin/zsh
# A regression check for how Redde names models and providers to Hermes, against unmodified Hermes
# releases. It runs each release on loopback with an isolated HERMES_HOME and two stub model
# endpoints that record which one a turn reached, then sends the requests the app sends.
#
#   scripts/hermes-lab/lab.sh run [tag ...]        every scenario on each release (default: DEFAULT_TAGS below)
#   scripts/hermes-lab/lab.sh run --app [tag ...]  the same, plus the app's own transport code (EchoTests)
#   scripts/hermes-lab/lab.sh approvals [tag ...]  the app's Dashboard client asked before a command runs
#   scripts/hermes-lab/lab.sh up <tag> <scenario>  leave one lab running (API :18642, Dashboard :19119)
#   scripts/hermes-lab/lab.sh down
#
# Releases are cloned and installed once into $REDDE_LAB_HOME (default ~/.cache/redde-hermes-lab);
# nothing touches ~/.hermes. Needs git, uv and python3. See README.md here for what is covered.
set -euo pipefail

HERE="${0:A:h}"
REPO="${HERE:h:h}"
LAB_HOME="${REDDE_LAB_HOME:-$HOME/.cache/redde-hermes-lab}"
DEFAULT_TAGS=(v2026.8.31 v2026.9.14 v2026.9.24)   # Hermes 0.21.0, 0.21.3, 0.21.5
SCENARIOS=(named two bare keyed leftover)
SIMULATOR="${REDDE_LAB_SIMULATOR:-iPhone 17 Pro}"
export LAB_HITS="$LAB_HOME/hits.jsonl"
export LAB_TARGET="$LAB_HOME/redde-lab-target"   # what the stub's "danger" command deletes

install() {
  local tag="$1" dir="$LAB_HOME/hermes-$1"
  [[ -x "$dir/.venv/bin/hermes" ]] && return
  echo "installing Hermes $tag into $dir …"
  rm -rf "$dir"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" https://github.com/NousResearch/hermes-agent.git "$dir" 2>/dev/null
  (cd "$dir" && uv venv -q --python 3.12 .venv && VIRTUAL_ENV="$dir/.venv" uv pip install -q -e ".[web]" aiohttp websockets)
}

down() {
  [[ -f "$LAB_HOME/pids" ]] || return 0
  while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$LAB_HOME/pids"
  rm -f "$LAB_HOME/pids"
  sleep 1
}

up() {
  local tag="$1" scenario="$2" hermes="$LAB_HOME/hermes-$1/.venv/bin/hermes"
  [[ -f "$HERE/scenarios/$scenario.yaml" ]] || { echo "no scenario '$scenario' (have: $SCENARIOS approval)"; exit 2; }
  install "$tag"
  down
  rm -rf "$LAB_HOME"/run-*(N) 2>/dev/null || true
  local run="$LAB_HOME/run-$$-$RANDOM"
  mkdir -p "$run/.hermes"
  export HERMES_HOME="$run/.hermes"
  cp "$HERE/scenarios/$scenario.yaml" "$HERMES_HOME/config.yaml"
  print -l "API_SERVER_ENABLED=true" "API_SERVER_KEY=labkey-labkey-labkey" "API_SERVER_PORT=18642" "API_SERVER_HOST=127.0.0.1" > "$HERMES_HOME/.env"
  # The Dashboard's login, for the one scenario that turns it on.
  [[ "$scenario" == approval ]] && print -l "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=lab" "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=labpass-labpass" \
    "HERMES_DASHBOARD_BASIC_AUTH_SECRET=0123456789abcdef0123456789abcdef0123456789abcdef" >> "$HERMES_HOME/.env"
  : > "$LAB_HITS"
  # No real keys may leak in: the point is to see where an unkeyed fallback goes.
  unset OPENROUTER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY HERMES_INFERENCE_PROVIDER 2>/dev/null || true
  (cd "$run"
   nohup python3 "$HERE/stub_llm.py" 18801 A alpha,beta > stubA.log 2>&1 & echo $! > "$LAB_HOME/pids"
   nohup python3 "$HERE/stub_llm.py" 18802 B gamma > stubB.log 2>&1 & echo $! >> "$LAB_HOME/pids"
   nohup "$hermes" serve --host 127.0.0.1 --port 19119 --skip-build > serve.log 2>&1 & echo $! >> "$LAB_HOME/pids"
   nohup "$hermes" gateway run > gateway.log 2>&1 & echo $! >> "$LAB_HOME/pids")
  local serve=000 api=000
  for _ in {1..120}; do
    serve=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:19119/api/status 2>/dev/null || true)
    api=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18642/health 2>/dev/null || true)
    [[ "$serve" == 200 && "$api" == 200 ]] && return 0
    sleep 1
  done
  echo "lab did not come up (serve=$serve api=$api); logs in $run"; return 1
}

# The app's own transport code against the running lab. The simulator shares the Mac's loopback.
APP_DEVICE=""
XCODE_ARGS=()

# Once per run: pick the simulator, boot it, and build the test bundle.
app_prepare() {
  # A name can match several simulators (one per runtime); xcodebuild wants exactly one.
  APP_DEVICE=$(xcrun simctl list devices available | grep -F "$SIMULATOR (" | head -1 | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' || true)
  [[ -n "$APP_DEVICE" ]] || { echo "no simulator named '$SIMULATOR' (set REDDE_LAB_SIMULATOR)"; return 1; }
  XCODE_ARGS=(-project Echo.xcodeproj -scheme Echo -destination "platform=iOS Simulator,id=$APP_DEVICE"
              -derivedDataPath DerivedData -only-testing:EchoTests/${1:-HermesLabTests})
  xcrun simctl bootstatus "$APP_DEVICE" -b > /dev/null 2>&1 || true
  echo "building EchoTests for the app check …"
  (cd "$REPO" && xcodebuild build-for-testing $XCODE_ARGS 2>&1 | grep -E ": error: |BUILD FAILED" || true)
}

app_check() {
  local out=""
  # The simulator sometimes refuses to launch the test host ("failed to launch", no test result),
  # or hangs doing so; that says nothing about the app, so try again, five minutes at most each.
  for _ in 1 2 3 4 5 6; do
    out=$(cd "$REPO" && perl -e 'alarm 300; exec @ARGV' xcodebuild test-without-building $XCODE_ARGS 2>&1 || true)
    [[ "$out" == *"  PASS"* || "$out" == *"  FAIL"* || "$out" == *"LAB SKIP"* ]] && break
    sleep 8
  done
  echo "App transport (${XCODE_ARGS[-1]#-only-testing:})"
  echo "$out" | grep -E "^  (PASS|FAIL)|LAB SKIP" || echo "  the test host never launched"
  [[ "$out" == *"TEST EXECUTE SUCCEEDED"* && "$out" == *"  PASS"* && "$out" != *"  FAIL"* ]]
}

run() {
  local with_app=0
  [[ "${1:-}" == "--app" ]] && { with_app=1; shift; }
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  if (( with_app )); then app_prepare || exit 1; fi
  for tag in $tags; do
    for scenario in $SCENARIOS; do
      echo "===== Hermes $tag / $scenario"
      if ! up "$tag" "$scenario"; then failed+=("$tag/$scenario (lab)"); continue; fi
      "$LAB_HOME/hermes-$tag/.venv/bin/python" "$HERE/check.py" both || failed+=("$tag/$scenario")
      if (( with_app )); then app_check || failed+=("$tag/$scenario (app)"); fi
    done
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

# From Hermes 0.21.3 the Dashboard asks its client for an approval in a different way, and from
# 0.21.5 only a client that says it can answer. The app's own client, signed in as on a real
# server, has to be asked on every release, and its yes and its no both have to count.
approvals() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  app_prepare HermesLabApprovalTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / approval"
    if ! up "$tag" approval; then failed+=("$tag (lab)"); continue; fi
    app_check || failed+=("$tag")
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

mkdir -p "$LAB_HOME"
case "${1:-}" in
  run) shift; run "$@" ;;
  approvals) shift; approvals "$@" ;;
  up) up "$2" "$3" && echo "lab up: Hermes $2 / $3 — API http://127.0.0.1:18642 (key labkey-labkey-labkey), Dashboard http://127.0.0.1:19119" ;;
  down) down ;;
  *) sed -n '2,14p' "$0"; exit 2 ;;
esac
