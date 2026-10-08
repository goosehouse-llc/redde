#!/bin/zsh
# A regression check for how Redde names models and providers to Hermes, against unmodified Hermes
# releases. It runs each release on loopback with an isolated HERMES_HOME and two stub model
# endpoints that record which one a turn reached, then sends the requests the app sends.
#
#   scripts/hermes-lab/lab.sh run [tag ...]        every scenario on each release (default: DEFAULT_TAGS below)
#   scripts/hermes-lab/lab.sh run --app [tag ...]  the same, plus the app's own transport code (EchoTests)
#   scripts/hermes-lab/lab.sh approvals [tag ...]  the app's Dashboard client asked before a command runs
#   scripts/hermes-lab/lab.sh signin [tag ...]     the app's Dashboard client signs in through a browser
#   scripts/hermes-lab/lab.sh admin [tag ...]      the Gateway screen's routes: status, MCP servers, logs, a restart
#   scripts/hermes-lab/lab.sh push [tag ...]       the push plugin: pairing, and a note for everything it announces
#   scripts/hermes-lab/lab.sh push --app [tag ...] the same, then the app pairs both ways and reads a notification
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
export LAB_APNS="$LAB_HOME/apns.jsonl"           # what the push scenario's stand-in for Apple received

install() {
  local tag="$1" dir="$LAB_HOME/hermes-$1"
  [[ -x "$dir/.venv/bin/hermes" ]] && return
  echo "installing Hermes $tag into $dir …"
  rm -rf "$dir"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" https://github.com/NousResearch/hermes-agent.git "$dir" 2>/dev/null
  (cd "$dir" && uv venv -q --python 3.12 .venv && VIRTUAL_ENV="$dir/.venv" uv pip install -q -e ".[web,mcp]" aiohttp websockets)
}

# The MCP SDK, for a copy installed before the lab asked for it: Hermes can't test an MCP server without.
with_mcp() {
  local dir="$LAB_HOME/hermes-$1"
  "$dir/.venv/bin/python" -c "import mcp" 2>/dev/null && return
  echo "adding the MCP SDK to Hermes $1 …"
  (cd "$dir" && VIRTUAL_ENV="$dir/.venv" uv pip install -q -e ".[web,mcp]")
}

down() {
  [[ -f "$LAB_HOME/pids" ]] || return 0
  while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$LAB_HOME/pids"
  rm -f "$LAB_HOME/pids"
  # A gateway that the Dashboard restarted (lab.sh admin) is a new process no list here has: it
  # is the lab's if it is a Hermes listening on the lab's API port.
  local pid
  for pid in $(lsof -ti tcp:18642 -sTCP:LISTEN 2>/dev/null); do
    [[ "$(ps -o command= -p "$pid" 2>/dev/null)" == *hermes* ]] && kill "$pid" 2>/dev/null || true
  done
  sleep 1
}

up() {
  local tag="$1" scenario="$2" hermes="$LAB_HOME/hermes-$1/.venv/bin/hermes"
  [[ -f "$HERE/scenarios/$scenario.yaml" ]] || { echo "no scenario '$scenario' (have: $SCENARIOS approval admin push)"; exit 2; }
  install "$tag"
  [[ "$scenario" == admin ]] && with_mcp "$tag"
  down
  rm -rf "$LAB_HOME"/run-*(N) 2>/dev/null || true
  local run="$LAB_HOME/run-$$-$RANDOM"
  mkdir -p "$run/.hermes"
  export HERMES_HOME="$run/.hermes"
  cp "$HERE/scenarios/$scenario.yaml" "$HERMES_HOME/config.yaml"
  print -l "API_SERVER_ENABLED=true" "API_SERVER_KEY=labkey-labkey-labkey" "API_SERVER_PORT=18642" "API_SERVER_HOST=127.0.0.1" > "$HERMES_HOME/.env"
  # The Dashboard's login, for the scenarios that turn it on.
  [[ "$scenario" == approval || "$scenario" == admin || "$scenario" == push ]] && print -l "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=lab" "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=labpass-labpass" \
    "HERMES_DASHBOARD_BASIC_AUTH_SECRET=0123456789abcdef0123456789abcdef0123456789abcdef" >> "$HERMES_HOME/.env"
  # An MCP server for the admin scenario to switch and test: the lab's own stand-in, off at first.
  [[ "$scenario" == admin ]] && print -l "mcp_servers:" "  lab-notes:" "    command: python3" "    args: [\"$HERE/mcp_stub.py\"]" "    enabled: false" >> "$HERMES_HOME/config.yaml"
  : > "$LAB_HITS"
  : > "$LAB_APNS"
  # A skill that needs a secret, for the stub's "lab:secret": opening it makes Hermes ask for one.
  mkdir -p "$HERMES_HOME/skills/lab-secret"
  print -l -- "---" "name: lab-secret" "description: Lab only. A skill that needs a secret." "required_environment_variables:" \
    "  - name: LAB_SECRET_TOKEN" "    prompt: Enter the lab token" "---" "" "# Lab secret" "" "Say hello." > "$HERMES_HOME/skills/lab-secret/SKILL.md"
  # The push scenario: the plugin from this repository, the relay on this machine (the Worker's
  # own code under Node) and a stand-in for Apple that records what it is sent.
  if [[ "$scenario" == push ]]; then
    mkdir -p "$HERMES_HOME/plugins"
    cp -R "$REPO/companion/hermes-plugin/redde-push" "$HERMES_HOME/plugins/redde-push"
    export REDDE_PUSH_RELAY=http://127.0.0.1:18980   # the relay the plugin offers an app that pairs over the Dashboard
  else
    unset REDDE_PUSH_RELAY 2>/dev/null || true
  fi
  # No real keys may leak in: the point is to see where an unkeyed fallback goes.
  unset OPENROUTER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY HERMES_INFERENCE_PROVIDER 2>/dev/null || true
  (cd "$run"
   nohup python3 "$HERE/stub_llm.py" 18801 A alpha,beta > stubA.log 2>&1 & echo $! > "$LAB_HOME/pids"
   nohup python3 "$HERE/stub_llm.py" 18802 B gamma > stubB.log 2>&1 & echo $! >> "$LAB_HOME/pids"
   if [[ "$scenario" == push ]]; then
     nohup python3 "$HERE/fake_apns.py" 18990 > apns.log 2>&1 & echo $! >> "$LAB_HOME/pids"
     nohup node "$REPO/companion/push-relay/test/local.mjs" 18980 http://127.0.0.1:18990 > relay.log 2>&1 & echo $! >> "$LAB_HOME/pids"
   fi
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
pick_simulator() {
  # A name can match several simulators (one per runtime); xcodebuild wants exactly one. A
  # simulator's own id (REDDE_LAB_SIMULATOR=<udid>) says which without doubt.
  APP_DEVICE=$(xcrun simctl list devices available | grep -F -e "$SIMULATOR (" -e "($SIMULATOR)" | head -1 | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' || true)
  [[ -n "$APP_DEVICE" ]] || { echo "no simulator named '$SIMULATOR' (set REDDE_LAB_SIMULATOR)"; return 1; }
  xcrun simctl bootstatus "$APP_DEVICE" -b > /dev/null 2>&1 || true
}

app_prepare() {
  pick_simulator || return 1
  XCODE_ARGS=(-project Echo.xcodeproj -scheme Echo -destination "platform=iOS Simulator,id=$APP_DEVICE"
              -derivedDataPath DerivedData -only-testing:EchoTests/${1:-HermesLabTests})
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
  echo "$out" | grep -E "^  (PASS|FAIL|----)|LAB SKIP" || echo "  the test host never launched"
  [[ "$out" == *"TEST EXECUTE SUCCEEDED"* && "$out" == *"  PASS"* && "$out" != *"  FAIL"* ]]
}

# The Gateway screen's routes, with the app's own client and model: status, the host, MCP servers
# switched and tested, logs, the update check (nothing is updated) and a restart followed to its end.
# Only a restart: Hermes's "start" installs a launchd or systemd service on the machine it runs on,
# and an update would fetch and install; neither belongs in a lab.
admin() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  app_prepare HermesLabAdminTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / admin"
    if ! up "$tag" admin; then failed+=("$tag (lab)"); continue; fi
    app_check || failed+=("$tag")
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
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

# A Dashboard that signs people in with Google or another provider has no password for the app:
# it signs in through a browser, by the Dashboard's native sign-in routes (Hermes 0.21 on). The
# app's own client has to get its tokens that way on every release, and keep them working.
signin() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  app_prepare HermesLabSignInTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / sign-in"
    if ! up "$tag" approval; then failed+=("$tag (lab)"); continue; fi
    app_check || failed+=("$tag")
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

# One turn over the lab's Hermes API, whose reply the push plugin announces.
api_turn() {
  local auth="Authorization: Bearer labkey-labkey-labkey" json="Content-Type: application/json" id
  # (A title may be used once.)
  id=$(curl -s -X POST http://127.0.0.1:18642/api/sessions -H "$auth" -H "$json" -d "{\"title\":\"Lab notification $(uuidgen)\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session"]["id"])')
  curl -s -o /dev/null --max-time 60 -X POST "http://127.0.0.1:18642/api/sessions/$id/chat/stream" -H "$auth" -H "$json" -d '{"input":"hi"}'
}

# The path with the real app: it opens a pairing link from the running lab's Hermes and pairs
# through the lab's relay; then Hermes replies, and the notification has to show the reply's text,
# which only someone holding the key agreed in the pairing can have read. The stand-in for Apple
# hands each notification to the simulator ($LAB_SIMULATOR, set before the lab came up) as a
# simulated push. That skips the app's notification extension, so what this proves is the app's
# half of the pairing and of the sealing; the extension opening a note while the app is closed
# takes a real push from Apple, on a phone.
push_app_check() {
  local hermes="$LAB_HOME/hermes-$1/.venv/bin/hermes" printed="$LAB_HOME/pair.out" link="" out=""
  : > "$printed"
  "$hermes" redde-push pair --relay http://127.0.0.1:18980 --wait 300 > "$printed" 2>&1 &
  local pairing=$!
  for _ in {1..40}; do
    link=$(grep -oE 'https://redde.goosehouse.org/connect#push=[^[:space:]]+' "$printed" | head -1 || true)
    [[ -n "$link" ]] && break
    sleep 1
  done
  echo "App, end to end (EchoUITests/PushPairingUITests)"
  [[ -n "$link" ]] || { echo "  FAIL  the plugin printed no pairing link"; kill $pairing 2>/dev/null; return 1; }
  link="redde://connect?${link#*#}"   # the app's own scheme: no website involved
  # Once the app is paired (the plugin's first note has reached "Apple"), Hermes replies a few
  # times, a while apart: the test waits for one of them.
  ( local before=$(wc -l < "$LAB_APNS")
    for _ in {1..200}; do (( $(wc -l < "$LAB_APNS") > before )) && break; sleep 1; done
    for _ in 1 2 3 4 5; do sleep 10; api_turn; done ) &
  local turns=$!
  out=$(cd "$REPO" && TEST_RUNNER_PUSH_LINK="$link" perl -e 'alarm 480; exec @ARGV' xcodebuild test-without-building \
        -project Echo.xcodeproj -scheme EchoUITests -destination "platform=iOS Simulator,id=$APP_DEVICE" -derivedDataPath DerivedData \
        -only-testing:EchoUITests/PushPairingUITests/testPairingWithTheLabsHermesThenANotification 2>&1 || true)
  kill $turns $pairing 2>/dev/null || true
  if [[ "$out" == *"TEST EXECUTE SUCCEEDED"* && "$out" != *"skipped"* ]]; then
    echo "  PASS  the app pairs with this Hermes and reads the notification for its next reply"
    return 0
  fi
  echo "  FAIL  the app pairs with this Hermes and reads the notification for its next reply"
  echo "$out" | grep -E "error: |XCTAssert|failed -" | head -6
  return 1
}

# The push plugin inside each release: a stand-in phone pairs through the relay, then replies and
# approvals over both connections have to reach it, sealed.
push() {
  local with_app=0
  [[ "${1:-}" == "--app" ]] && { with_app=1; shift; }
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  if (( with_app )); then
    app_prepare HermesLabPushTests || exit 1   # (the app's own client and push service against the plugin)
    export LAB_SIMULATOR="$APP_DEVICE"
    echo "building EchoUITests for the app check …"
    (cd "$REPO" && xcodebuild build-for-testing -project Echo.xcodeproj -scheme EchoUITests -destination "platform=iOS Simulator,id=$APP_DEVICE" \
       -derivedDataPath DerivedData 2>&1 | grep -E ": error: |BUILD FAILED" || true)
  fi
  for tag in $tags; do
    echo "===== Hermes $tag / push"
    if ! up "$tag" push; then failed+=("$tag (lab)"); continue; fi
    "$LAB_HOME/hermes-$tag/.venv/bin/python" "$HERE/push_check.py" "$LAB_HOME/hermes-$tag/.venv/bin/hermes" || failed+=("$tag")
    if (( with_app )); then
      app_check || failed+=("$tag (app, one step)")
      push_app_check "$tag" || failed+=("$tag (app, by code)")
    fi
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

mkdir -p "$LAB_HOME"
case "${1:-}" in
  run) shift; run "$@" ;;
  approvals) shift; approvals "$@" ;;
  signin) shift; signin "$@" ;;
  admin) shift; admin "$@" ;;
  push) shift; push "$@" ;;
  up) up "$2" "$3" && echo "lab up: Hermes $2 / $3 — API http://127.0.0.1:18642 (key labkey-labkey-labkey), Dashboard http://127.0.0.1:19119" ;;
  down) down ;;
  *) sed -n '2,17p' "$0"; exit 2 ;;
esac
