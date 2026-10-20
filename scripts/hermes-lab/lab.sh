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
#   scripts/hermes-lab/lab.sh controls [tag ...]   a conversation's own switches (run without asking, fast mode) and a move to a project
#   scripts/hermes-lab/lab.sh todos [tag ...]      the agent's task list as a checklist, live and reopened, on both Hermes connections
#   scripts/hermes-lab/lab.sh files [tag ...]      the file browser: list, upload, download, edit text, make folders, delete
#   scripts/hermes-lab/lab.sh plugin [tag ...]     the notification plugin installed through the Dashboard (fetches it from GitHub)
#   scripts/hermes-lab/lab.sh push [tag ...]       the push plugin: pairing, and a note for everything it announces
#   scripts/hermes-lab/lab.sh push --app [tag ...] the same, then the app pairs both ways and reads a notification
#   scripts/hermes-lab/lab.sh device [tag ...]     phone tools: the agent calls one, a stand-in phone answers, on both connections
#   scripts/hermes-lab/lab.sh device --app [tag ...] the same, then the app's own service carries one out
#   scripts/hermes-lab/lab.sh switch [tag ...]     a turn left for another conversation goes on (issue 12), then the app's conversation
#   scripts/hermes-lab/lab.sh projects [tag ...]   projects made in the app: a folder in ~/Projects (the lab's own home), a conversation in it
#   scripts/hermes-lab/lab.sh search [tag ...]     searching inside messages: words said on either connection, found through the Dashboard
#   scripts/hermes-lab/lab.sh context [tag ...]    Settings' context and memory files, found where Hermes keeps them (issue 15)
#   scripts/hermes-lab/lab.sh speech [tag ...]     replies read out with the voice Hermes is set up with, streamed and whole (issue 7)
#   scripts/hermes-lab/lab.sh status [tag ...]     the chat list's marks: working, waiting on a person, unread, on both connections
#   scripts/hermes-lab/lab.sh bots [tag ...]       bots: each profile's own chat, hidden from the list, and bots messaging bots
#   scripts/hermes-lab/lab.sh groups [tag ...]     group chats: a room of bots made, talked to, a bot tagged, stopped, renamed, disbanded
#   scripts/hermes-lab/lab.sh runs [tag ...]       Hermes API turns as runs: left, taken up again, stopped, sent twice (app check)
#   scripts/hermes-lab/lab.sh butler [--app] [tag ...]  the main profile hands coding to a claude bot (kanban), Claude Code
#                                                  runs on another machine over SSH, the patch comes back and is applied
#                                                  after asking; --app: the app's open conversation gets that question
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
  local tag="$1" dir="$LAB_HOME/hermes-$1" py=3.12
  # 0.22 declares every dependency for Python 3.14 only: on 3.12 it installs none and can't start.
  [[ "$tag" == v2026.* ]] || py=3.14
  [[ -x "$dir/.venv/bin/hermes" ]] && return
  echo "installing Hermes $tag into $dir …"
  rm -rf "$dir"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" https://github.com/NousResearch/hermes-agent.git "$dir" 2>/dev/null
  (cd "$dir" && uv venv -q --python $py .venv && VIRTUAL_ENV="$dir/.venv" uv pip install -q -e ".[web,mcp]" aiohttp websockets)
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
  [[ -f "$HERE/scenarios/$scenario.yaml" ]] || { echo "no scenario '$scenario' (have: $SCENARIOS approval admin push speech speech-whole)"; exit 2; }
  install "$tag"
  [[ "$scenario" == admin ]] && with_mcp "$tag"
  down
  rm -rf "$LAB_HOME"/run-*(N) 2>/dev/null || true
  local run="$LAB_HOME/run-$$-$RANDOM"
  mkdir -p "$run/.hermes"
  export HERMES_HOME="$run/.hermes"
  # (@LAB@ in a scenario is this folder: a voice that runs one of the lab's scripts.)
  sed "s#@LAB@#$HERE#g" "$HERE/scenarios/$scenario.yaml" > "$HERMES_HOME/config.yaml"
  print -l "API_SERVER_ENABLED=true" "API_SERVER_KEY=labkey-labkey-labkey" "API_SERVER_PORT=18642" "API_SERVER_HOST=127.0.0.1" > "$HERMES_HOME/.env"
  # The Dashboard's login, for the scenarios that turn it on.
  [[ "$scenario" == (approval|admin|push|speech|speech-whole|butler) ]] && print -l "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=lab" "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=labpass-labpass" \
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
  if [[ "$scenario" == butler ]]; then
    butler_setup "$run" || return 1
    export LAB_BUTLER="$run" LAB_HOOK_LOG="$run/hook.jsonl" PATH="$run/bin:$PATH"
  else
    unset LAB_BUTLER LAB_HOOK_LOG 2>/dev/null || true
  fi
  # No real keys may leak in: the point is to see where an unkeyed fallback goes.
  unset OPENROUTER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY HERMES_INFERENCE_PROVIDER 2>/dev/null || true
  (cd "$run"
   # A home of the lab's own for the checks that write to ~ on the server (projects in ~/Projects).
   if [[ -n "${LAB_OWN_HOME:-}" ]]; then export HOME="$run/home"; mkdir -p "$HOME"; fi
   nohup python3 "$HERE/stub_llm.py" 18801 A alpha,beta > stubA.log 2>&1 & echo $! > "$LAB_HOME/pids"
   nohup python3 "$HERE/stub_llm.py" 18802 B gamma > stubB.log 2>&1 & echo $! >> "$LAB_HOME/pids"
   if [[ "$scenario" == push ]]; then
     nohup python3 "$HERE/fake_apns.py" 18990 > apns.log 2>&1 & echo $! >> "$LAB_HOME/pids"
     nohup node "$REPO/companion/push-relay/test/local.mjs" 18980 http://127.0.0.1:18990 > relay.log 2>&1 & echo $! >> "$LAB_HOME/pids"
   fi
   if [[ "$scenario" == butler ]]; then
     nohup /usr/sbin/sshd -D -e -f "$run/ssh/sshd_config" > sshd.log 2>&1 & echo $! >> "$LAB_HOME/pids"
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
  echo "lab did not come up (serve=$serve api=$api); logs in $run"
  # The next lab clears those logs away: say now what the two last wrote.
  tail -n 8 "$run/serve.log" "$run/gateway.log" 2>/dev/null | cut -c1-300
  return 1
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

# Leaving a conversation while the agent works in it (GitHub issue 12): what Hermes does with a
# turn nobody listens to any more (switch_check.py), then the app's own conversation leaving one
# and coming back to it on both connections (HermesLabSwitchTests).
switch() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  app_prepare HermesLabSwitchTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / approval"
    if ! up "$tag" approval; then failed+=("$tag (lab)"); continue; fi
    (cd "$HERE" && "$LAB_HOME/hermes-$tag/.venv/bin/python" switch_check.py) || failed+=("$tag (host)")
    app_check || failed+=("$tag")
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

# The chat list's marks: what Hermes says while a conversation's turn runs, while it waits on a
# person, and about replies nobody has read, on both connections (status_check.py), then the app's
# own ChatActivity with its clients (HermesLabStatusTests).
list_status() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  app_prepare HermesLabStatusTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / approval"
    if ! up "$tag" approval; then failed+=("$tag (lab)"); continue; fi
    (cd "$HERE" && "$LAB_HOME/hermes-$tag/.venv/bin/python" status_check.py) || failed+=("$tag (host)")
    app_check || failed+=("$tag")
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

# The agent's task list: the stub writes one with Hermes's to-do tool and merges into it, and the
# app has to have the list after each, live and from the stored transcript, on both connections.
plugin() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  app_prepare HermesLabPluginTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / approval"
    if ! up "$tag" approval; then failed+=("$tag (lab)"); continue; fi
    app_check || failed+=("$tag")
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

files() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  app_prepare HermesLabFilesTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / approval"
    if ! up "$tag" approval; then failed+=("$tag (lab)"); continue; fi
    app_check || failed+=("$tag")
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

todos() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  app_prepare HermesLabTodoTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / approval"
    if ! up "$tag" approval; then failed+=("$tag (lab)"); continue; fi
    app_check || failed+=("$tag")
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

# Group chats (Hermes's hosted bot rooms): what Hermes does with a room (groups_check.py), then the
# app's own client and room following (HermesLabGroupsTests). LAB_HOST_ONLY=1 skips the app.
groups() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  [[ -n "${LAB_HOST_ONLY:-}" ]] || app_prepare HermesLabGroupsTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / approval"
    # (A home of the lab's own: Hermes 0.21.0 puts a command for each new profile in ~/.local/bin.)
    if ! LAB_OWN_HOME=1 up "$tag" approval; then failed+=("$tag (lab)"); continue; fi
    (cd "$HERE" && "$LAB_HOME/hermes-$tag/.venv/bin/python" groups_check.py) || failed+=("$tag (host)")
    if [[ -z "${LAB_HOST_ONLY:-}" ]]; then
      LAB_OWN_HOME=1 up "$tag" approval || { failed+=("$tag (lab)"); continue; }
      app_check || failed+=("$tag")
    fi
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

# The butler: the main profile ("Sol") hands a coding task to a "claude" bot on the kanban board; the
# bot's worker runs Claude Code (fakebin/claude, the lab's stand-in) on "Workbox" through its SSH
# terminal; Sol, woken when the card is done, applies the patch as it is, and Hermes asks first
# (ask_before_writes.py). "Workbox" is this Mac through an SSH server of the lab's own on 18222 with
# its own keys, known-hosts file and home: nothing touches ~/.ssh. Its login is fenced off from the
# Hermes home and the host's repository (sandbox-exec), as a second machine would be. The main
# profile's .env holds a canary the bot must never see.
butler_setup() {
  local run="$1" ssh="$1/ssh" user
  user="$(id -un)"
  mkdir -p "$ssh" "$run/bin" "$run/workbox/home/work" "$run/host" "$run/kanban-work"
  print "LAB_CANARY_KEY=canary-$RANDOM$RANDOM$RANDOM" >> "$HERMES_HOME/.env"
  ssh-keygen -q -t ed25519 -N "" -C lab-host -f "$ssh/host_key"
  ssh-keygen -q -t ed25519 -N "" -C lab-client -f "$ssh/client_key"
  cp "$ssh/client_key.pub" "$ssh/authorized_keys"
  local fence="(version 1)(allow default)(deny file-read* file-write* (subpath \"$run/.hermes\") (subpath \"$run/host\"))"
  print -l "#!/bin/sh" "export HOME='$run/workbox/home' LAB_RUN='$run' PATH='$HERE/fakebin:/usr/bin:/bin:/usr/sbin:/sbin'" 'cd "$HOME"' \
    "FENCE='$fence'" \
    'if [ -n "$SSH_ORIGINAL_COMMAND" ]; then exec /usr/bin/sandbox-exec -p "$FENCE" /bin/bash -c "$SSH_ORIGINAL_COMMAND"; fi' \
    'exec /usr/bin/sandbox-exec -p "$FENCE" /bin/bash -l' > "$ssh/login.sh"
  chmod +x "$ssh/login.sh"
  print -l "Port 18222" "ListenAddress 127.0.0.1" "HostKey $ssh/host_key" "PidFile $ssh/sshd.pid" "AuthorizedKeysFile $ssh/authorized_keys" \
    "PasswordAuthentication no" "KbdInteractiveAuthentication no" "PubkeyAuthentication yes" "UsePAM no" "StrictModes no" \
    "ForceCommand $ssh/login.sh" "AllowTcpForwarding no" "X11Forwarding no" > "$ssh/sshd_config"
  print -l "Host workbox" "  HostName 127.0.0.1" "  Port 18222" "  User $user" "  IdentityFile $ssh/client_key" \
    "Host *" "  IdentitiesOnly yes" "  UserKnownHostsFile $ssh/known_hosts" "  GlobalKnownHostsFile /dev/null" \
    "  StrictHostKeyChecking accept-new" "  BatchMode yes" > "$ssh/ssh_config"
  print -l "#!/bin/sh" "exec /usr/bin/ssh -F '$ssh/ssh_config' \"\$@\"" > "$run/bin/ssh"
  print -l "#!/bin/sh" "exec /usr/bin/scp -O -F '$ssh/ssh_config' \"\$@\"" > "$run/bin/scp"
  chmod +x "$run/bin/ssh" "$run/bin/scp"
  # The repository on the Hermes host, and the copy "Workbox" has of it (as both would have GitHub's).
  (cd "$run/host" && git init -q repo && cd repo && git config user.name Lab && git config user.email lab@example.invalid \
    && print 'print("hello")' > hello.py && git add hello.py && git commit -q -m start) || return 1
  git clone -q --bare "$run/host/repo" "$run/workbox/origin" || return 1
  # The claude bot: its own model (stub B), no keys of its own, its terminal on "Workbox".
  local bot="$HERMES_HOME/profiles/claude"
  mkdir -p "$bot"
  : > "$bot/.env"
  print -l "model:" "  default: gamma" "  provider: custom:stub-b" "custom_providers:" "  - name: Stub B" \
    "    base_url: http://127.0.0.1:18802/v1" "    api_key: sk-stub" "    model: gamma" "    api_mode: chat_completions" \
    "terminal:" "  backend: ssh" "  ssh_host: 127.0.0.1" "  ssh_user: $user" "  ssh_port: 18222" "  ssh_key: $ssh/client_key" \
    "approvals:" "  mode: manual" > "$bot/config.yaml"
  print -l "description: Coding worker. Does each task with Claude Code on Workbox and sends back a patch." \
    "ui_meta:" "  hermes-bots:" "    title: Claude" > "$bot/profile.yaml"
  # A variant of the setup kept elsewhere (LAB_BUTLER_EXTRA, a zsh script): it may change any of
  # the above before Hermes starts. `run`, `hermes`, `HERE` and HERMES_HOME are set.
  [[ -z "${LAB_BUTLER_EXTRA:-}" ]] || source "$LAB_BUTLER_EXTRA" || return 1
}

butler() {
  local app=""
  [[ "${1:-}" == --app ]] && { app=1; shift; }
  local tags=("${@:-v0.22.2}") failed=()
  [[ -z "$app" ]] || app_prepare HermesLabButlerTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / butler"
    if ! up "$tag" butler; then failed+=("$tag (lab)"); continue; fi
    # (LAB_BUTLER_CHECK: another check, for a variant of the setup.)
    (cd "$HERE" && "$LAB_HOME/hermes-$tag/.venv/bin/python" "${LAB_BUTLER_CHECK:-butler_check.py}") || failed+=("$tag (host)")
    if [[ -n "$app" ]]; then
      up "$tag" butler || { failed+=("$tag (lab)"); continue; }
      app_check || failed+=("$tag")
    fi
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

# Hermes API turns as runs (the API half of GitHub issue 12): what Hermes does with a run whose
# events are dropped, and with the chat stream's (switch_check.py), then the app's own transport
# leaving, taking up, stopping and sending a run again (HermesLabRunsTests).
runs() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  app_prepare HermesLabRunsTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / approval"
    if ! up "$tag" approval; then failed+=("$tag (lab)"); continue; fi
    (cd "$HERE" && "$LAB_HOME/hermes-$tag/.venv/bin/python" switch_check.py) || failed+=("$tag (host)")
    app_check || failed+=("$tag")
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

# Bots (Hermes's Bot Mode): what Hermes does with a profile's own chat and with a profile set up as
# a bot (bots_check.py), then the app's own client opening a bot's chat, talking in it, mentioning
# another bot, and making, changing and deleting one (HermesLabBotsTests). In a home of the lab's
# own: Hermes 0.21.0 puts a command for each new profile in ~/.local/bin, whatever it is asked.
bots() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  [[ -n "${LAB_HOST_ONLY:-}" ]] || app_prepare HermesLabBotsTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / approval"
    if ! LAB_OWN_HOME=1 up "$tag" approval; then failed+=("$tag (lab)"); continue; fi
    (cd "$HERE" && "$LAB_HOME/hermes-$tag/.venv/bin/python" bots_check.py) || failed+=("$tag (host)")
    if [[ -z "${LAB_HOST_ONLY:-}" ]]; then
      # The host check left a bot and its chat behind: the app starts on a fresh lab.
      LAB_OWN_HOME=1 up "$tag" approval || { failed+=("$tag (lab)"); continue; }
      app_check || failed+=("$tag")
    fi
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

# Projects as the app makes them, with the app's own client: one made (its folder in ~/Projects,
# which here is a home of the lab's own, never yours), a conversation started in it, one moved
# into another, renamed and removed.
projects() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  app_prepare HermesLabProjectsTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / approval"
    if ! LAB_OWN_HOME=1 up "$tag" approval; then failed+=("$tag (lab)"); continue; fi
    app_check || failed+=("$tag")
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

# Settings' context and memory files, with the app's own client (GitHub issue 15). Hermes's home
# is the lab's run folder and ~ a home of the lab's own, so ~/.hermes is empty, as on a Docker
# host: SOUL.md and MEMORY.md are put in Hermes's home, and the app must find them there.
context() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  app_prepare HermesLabContextFilesTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / approval"
    if ! LAB_OWN_HOME=1 up "$tag" approval; then failed+=("$tag (lab)"); continue; fi
    mkdir -p "$HERMES_HOME/memories"
    print "Lab soul for issue 15." > "$HERMES_HOME/SOUL.md"
    print "Lab memory for issue 15." > "$HERMES_HOME/memories/MEMORY.md"
    app_check || failed+=("$tag")
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

# A conversation's own switches, with the app's own client: running commands without asking (the
# stub's rm -rf then runs unasked, and is asked about again when the switch is off), fast mode
# refused for a model that has none, and a move to a project.
search() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  app_prepare HermesLabSearchTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / approval"
    if ! LAB_OWN_HOME=1 up "$tag" approval; then failed+=("$tag (lab)"); continue; fi
    app_check || failed+=("$tag")
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

controls() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  app_prepare HermesLabChatControlsTests || exit 1
  for tag in $tags; do
    echo "===== Hermes $tag / approval"
    if ! up "$tag" approval; then failed+=("$tag (lab)"); continue; fi
    app_check || failed+=("$tag")
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
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

# Phone tools inside each release: the agent calls one, a stand-in phone answers it over the
# Dashboard, and the answer has to reach the model, over both connections.
device() {
  local with_app=0
  [[ "${1:-}" == "--app" ]] && { with_app=1; shift; }
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  (( with_app )) && { app_prepare HermesLabDeviceTests || exit 1 }   # (the app's own client, service and files tool)
  for tag in $tags; do
    echo "===== Hermes $tag / phone tools"
    if ! up "$tag" push; then failed+=("$tag (lab)"); continue; fi
    "$LAB_HOME/hermes-$tag/.venv/bin/python" "$HERE/device_check.py" || failed+=("$tag")
    if (( with_app )); then app_check || failed+=("$tag (app)"); fi
  done
  down
  if (( ${#failed} )); then echo "\nFAILED: $failed"; exit 1; fi
  echo "\nAll checks passed."
}

# Replies read out by the voice Hermes is set up with, through the Dashboard (GitHub issue 7): a
# voice that streams (the stub's "OpenAI"), and one that runs on the server and only writes whole
# files (tts_command.py). LAB_SPEAKS tells the app's check which the socket should do: stream, or
# say "fallback" so the app asks for each sentence whole (up to 0.21.5, for the second voice).
speech() {
  local tags=("${@:-$DEFAULT_TAGS[@]}") failed=()
  app_prepare HermesLabSpeechTests || exit 1
  for tag in $tags; do
    for scenario in speech speech-whole; do
      echo "===== Hermes $tag / $scenario"
      if ! up "$tag" "$scenario"; then failed+=("$tag $scenario (lab)"); continue; fi
      local speaks=stream voice=openai
      [[ "$scenario" == speech-whole ]] && voice=lab-tone
      [[ "$scenario" == speech-whole && "$tag" == v2026.* ]] && speaks=whole
      # (xcodebuild hands TEST_RUNNER_ variables to the tests without the prefix.)
      export TEST_RUNNER_LAB_SPEAKS=$speaks TEST_RUNNER_LAB_VOICE=$voice
      app_check || failed+=("$tag $scenario")
    done
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
  controls) shift; controls "$@" ;;
  todos) shift; todos "$@" ;;
  files) shift; files "$@" ;;
  plugin) shift; plugin "$@" ;;
  push) shift; push "$@" ;;
  device) shift; device "$@" ;;
  switch) shift; switch "$@" ;;
  status) shift; list_status "$@" ;;
  projects) shift; projects "$@" ;;
  bots) shift; bots "$@" ;;
  runs) shift; runs "$@" ;;
  butler) shift; butler "$@" ;;
  groups) shift; groups "$@" ;;
  search) shift; search "$@" ;;
  context) shift; context "$@" ;;
  speech) shift; speech "$@" ;;
  up) up "$2" "$3" && echo "lab up: Hermes $2 / $3 — API http://127.0.0.1:18642 (key labkey-labkey-labkey), Dashboard http://127.0.0.1:19119" ;;
  down) down ;;
  *) sed -n '2,26p' "$0"; exit 2 ;;
esac
