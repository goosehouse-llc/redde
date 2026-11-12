#!/bin/zsh
# Redde's ACP connection against a real agent on loopback: the Redde bridge
# (companion/redde-bridge) in front of `hermes acp` from the Hermes lab, answered by the lab's
# stub model, so nothing reaches a real model or ~/.hermes.
#
#   scripts/acp-lab.sh up      stub on :18801, bridge on ws://127.0.0.1:18765 (token "labtoken")
#   scripts/acp-lab.sh down
#   scripts/acp-lab.sh status
#
# In the app: Add Server → Other agent (ACP), address 127.0.0.1:18765, token labtoken, agent
# Hermes. "please do the danger thing" asks before a command, "lab:todo" makes a plan.
# Needs the lab's Hermes 0.22.7 install (scripts/hermes-lab/lab.sh installs releases).
set -euo pipefail

HERE="${0:A:h}"
REPO="${HERE:h}"
LAB_HOME="${REDDE_LAB_HOME:-$HOME/.cache/redde-hermes-lab}"
HERMES="${REDDE_ACP_HERMES:-$LAB_HOME/hermes-v0.22.7}"
RUN="$LAB_HOME/acp-lab"
PORT="${REDDE_ACP_PORT:-18765}"
STUB_PORT=18801

up() {
  [[ -x "$HERMES/.venv/bin/hermes-acp" ]] || { echo "no hermes-acp in $HERMES (install the release with the Hermes lab)"; exit 1; }
  down quiet
  mkdir -p "$RUN/home" "$RUN/work"
  cat > "$RUN/home/config.yaml" <<EOF
model:
  default: alpha
  provider: custom:my-local
custom_providers:
  - name: My Local
    base_url: http://127.0.0.1:$STUB_PORT/v1
    api_key: sk-stub
    model: alpha
    api_mode: chat_completions
    models:
      alpha: {}
      beta: {}
EOF
  cat > "$RUN/bridge.toml" <<EOF
listen = "127.0.0.1:$PORT"
token = "labtoken"

[agents.hermes]
name = "Hermes"
command = ["$HERMES/.venv/bin/hermes-acp"]
cwd = "$RUN/work"
env = { HERMES_HOME = "$RUN/home" }
EOF
  LAB_HITS="$RUN/hits.jsonl" LAB_TARGET="$RUN/redde-lab-target" \
    nohup python3 "$REPO/scripts/hermes-lab/stub_llm.py" $STUB_PORT A alpha,beta > "$RUN/stub.log" 2>&1 &
  echo $! > "$RUN/stub.pid"
  nohup python3 "$REPO/companion/redde-bridge/redde_bridge.py" --config "$RUN/bridge.toml" -v > "$RUN/bridge.log" 2>&1 &
  echo $! > "$RUN/bridge.pid"
  for _ in {1..40}; do
    curl -sf -H "Authorization: Bearer labtoken" "http://127.0.0.1:$PORT/agents" > /dev/null && break
    sleep 0.25
  done
  status
  echo "logs: $RUN/bridge.log, $RUN/stub.log"
}

down() {
  for name in bridge stub; do
    local file="$RUN/$name.pid"
    [[ -f "$file" ]] || continue
    kill "$(cat "$file")" 2>/dev/null || true
    rm -f "$file"
  done
  # The bridge's agents go with it; a stray hermes-acp of this lab's home is ended too.
  pkill -f "HERMES_HOME=$RUN/home" 2>/dev/null || true
  [[ "${1:-}" == quiet ]] || echo "acp lab down"
}

status() {
  if curl -sf -H "Authorization: Bearer labtoken" "http://127.0.0.1:$PORT/agents"; then
    echo; echo "bridge up: ws://127.0.0.1:$PORT (token labtoken)"
  else
    echo "bridge not answering on :$PORT"
  fi
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) status ;;
  *) sed -n 2,12p "$0"; exit 1 ;;
esac
