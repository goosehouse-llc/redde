#!/bin/zsh
# A real OpenSSH server for the terminal's checks (EchoTests/TerminalLabTests), on 127.0.0.1:2222,
# run as you with a host key, config and authorized_keys of its own under the lab folder: your
# ~/.ssh is never read or written. The shells it starts read the lab's zsh files (ZDOTDIR), not
# yours, and keep their history there.
#
#   scripts/terminal-lab/lab.sh up      start it (again)
#   scripts/terminal-lab/lab.sh test    start it, run TerminalLabTests in the simulator, stop it
#   scripts/terminal-lab/lab.sh down
set -euo pipefail

HERE="${0:A:h}"
REPO="${HERE:h:h}"
LAB="${REDDE_TERMINAL_LAB:-$HOME/.cache/redde-terminal-lab}"
PORT=2222
SIMULATOR="${REDDE_LAB_SIMULATOR:-iPhone 17 Pro}"

down() {
  [[ -f "$LAB/sshd.pid" ]] && kill "$(cat "$LAB/sshd.pid")" 2>/dev/null || true
  rm -f "$LAB/sshd.pid"
}

up() {
  down
  mkdir -p "$LAB/zdotdir" "$LAB/projects/demo folder"
  [[ -f "$LAB/host_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C redde-terminal-lab -f "$LAB/host_ed25519"
  # The checks put this device's key here themselves (and take it out to see a refusal).
  touch "$LAB/authorized_keys"; chmod 600 "$LAB/authorized_keys"
  print -l "PS1='lab%# '" "HISTFILE='$LAB/history'" > "$LAB/zdotdir/.zshrc"
  print -l \
    "Port $PORT" "ListenAddress 127.0.0.1" "HostKey $LAB/host_ed25519" "PidFile $LAB/sshd.pid" \
    "AuthorizedKeysFile $LAB/authorized_keys" "StrictModes no" "UsePAM no" \
    "PubkeyAuthentication yes" "PasswordAuthentication no" "KbdInteractiveAuthentication no" \
    "AllowUsers $USER" "SetEnv ZDOTDIR=$LAB/zdotdir" "LogLevel VERBOSE" > "$LAB/sshd_config"
  /usr/sbin/sshd -f "$LAB/sshd_config" -E "$LAB/sshd.log"
  ssh-keygen -lf "$LAB/host_ed25519.pub" | awk '{print $2}' > "$LAB/fingerprint"
  for _ in {1..20}; do nc -z 127.0.0.1 $PORT 2>/dev/null && { echo "terminal lab up: 127.0.0.1:$PORT as $USER, $(cat "$LAB/fingerprint")"; return 0; }; sleep 0.3; done
  echo "sshd did not start; its log:"; tail -n 20 "$LAB/sshd.log"; return 1
}

check() {
  up
  local id=$(xcrun simctl list devices available | grep -F "$SIMULATOR (" | head -1 | grep -oE '[0-9A-F-]{36}')
  # The simulator shares the Mac's loopback and file system; TEST_RUNNER_ hands the test these.
  (cd "$REPO" && TEST_RUNNER_REDDE_TERMINAL_LAB="$LAB" TEST_RUNNER_REDDE_TERMINAL_USER="$USER" \
    xcodebuild test -project Echo.xcodeproj -scheme Echo -destination "id=$id" -derivedDataPath DerivedData-tests \
    -only-testing:EchoTests/TerminalLabTests 2>&1 | grep -E "^  (PASS|FAIL)|LAB SKIP|✘|error:|TEST (EXECUTE )?(SUCCEEDED|FAILED)") || true
  down
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  test) check ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
