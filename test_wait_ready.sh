#!/usr/bin/env bash
set -euo pipefail

# The stages
# - first boot: boot and allow cloud init to configure
#   - fde paraphrase
#   - login
#   - reboot
# - second boot: boot up and hibernate
#   - fde paraphrase
#   - login
#   - write something to a temp file that is kept in memory (persistent over hibernate but not reboot)
#   - hibernate



DISK_IMG="/home/bryce/vm/ubuntu-fde-hibernate/vm-disk.qcow2"
SESSION="vmconsole"
WINDOW="1"
PANE="${SESSION}:${WINDOW}"
PASSPHRASE="pass"
USERNAME="ubuntu"
PASSWORD="pass"
TMPDIR="$(mktemp -d)"
CLOUDISO="${TMPDIR}/cloud.iso"


time_vm_start=$(date +%s)


wait_for_prompt_and_send() {
  local prompt="$1"
  local input="$2"
  local num_lines="${3:-10}"
  local delay="${4:-1}"
  echo "[*] Waiting for prompt: $prompt"
  while true; do
    now=$(date +%s)
    pane_height=$(tmux display -p -t "$PANE" '#{pane_height}')
    START_LINE=$((pane_height - num_lines))
    OUTPUT=$(tmux capture-pane -p -S ${START_LINE} -E -  -t "$PANE")
    echo "$OUTPUT"
    # use regex matching
    if echo "$OUTPUT" | grep -qiE "$prompt"; then
      now=$(date +%s)
      echo "[*] Sending input for prompt: $prompt +$((now - time_vm_start)) seconds"
      tmux send-keys -t "$PANE" "$input" Enter
      break
    fi
    sleep "$delay"
  done
}

wait_for_prompt_and_send "^Cloud-init v\..* finished at .*$" "q"


