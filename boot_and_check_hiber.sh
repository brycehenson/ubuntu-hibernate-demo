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
# - resume from hibernate
#   - check that the file we wrote is still there

DISK_IMG="/home/bryce/vm/ubuntu-demo/vm-disk.qcow2"
SESSION="vmconsole"
WINDOW="1"
PANE="${SESSION}:${WINDOW}"
PASSPHRASE="pass"
USERNAME="ubuntu"
PASSWORD="pass"
CUSTOM_LUKS_PROMPT_MARKER="Hi there friend, thanks for finding my laptop !"
CUSTOM_LUKS_PROMPT_SCRIPT_PATH="scripts/local-top/00-custom-crypt-prompt"
TMPDIR="$(mktemp -d)"
CLOUDISO="${TMPDIR}/cloud.iso"

# Resolve OVMF firmware for UEFI boot; allow overrides via env vars
DEFAULT_OVMF_CODE=(/usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd)
DEFAULT_OVMF_VARS=(/usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd)

if [[ -z "${OVMF_CODE:-}" ]]; then
  for candidate in "${DEFAULT_OVMF_CODE[@]}"; do
    if [[ -r "$candidate" ]]; then
      OVMF_CODE="$candidate"
      break
    fi
  done
fi

if [[ -z "${OVMF_VARS_TEMPLATE:-}" ]]; then
  for candidate in "${DEFAULT_OVMF_VARS[@]}"; do
    if [[ -r "$candidate" ]]; then
      OVMF_VARS_TEMPLATE="$candidate"
      break
    fi
  done
fi

if [[ -z "${OVMF_CODE:-}" ]] || [[ ! -r "$OVMF_CODE" ]]; then
  cat <<EOF >&2
[!] OVMF_CODE firmware missing or unreadable at: ${OVMF_CODE:-<unset>}
    Checked candidates: ${DEFAULT_OVMF_CODE[*]}
    Install 'ovmf' (e.g. sudo apt install ovmf) or set OVMF_CODE to the correct file.
EOF
  exit 1
fi

if [[ -z "${OVMF_VARS_TEMPLATE:-}" ]] || [[ ! -r "$OVMF_VARS_TEMPLATE" ]]; then
  cat <<EOF >&2
[!] OVMF_VARS_TEMPLATE missing or unreadable at: ${OVMF_VARS_TEMPLATE:-<unset>}
    Checked candidates: ${DEFAULT_OVMF_VARS[*]}
    Install 'ovmf' or set OVMF_VARS_TEMPLATE to the matching vars image.
EOF
  exit 1
fi

OVMF_VARS="${TMPDIR}/OVMF_VARS.fd"
cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"
chmod u+rw,go-rwx "$OVMF_VARS"


cleanup() {
  echo "[*] Cleaning up…"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
   sudo rm -rf "$TMPDIR"
}
trap cleanup EXIT

is_kde_session() {
  [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]] || \
    [[ "${DESKTOP_SESSION:-}" == *kde* ]] || \
    [[ -n "${KDE_FULL_SESSION:-}" ]]
}

is_gnome_session() {
  [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]] || \
    [[ "${DESKTOP_SESSION:-}" == *gnome* ]]
}

launch_tmux_viewer() {
  local attach_cmd=(tmux attach-session -t "$SESSION")

  if is_kde_session && command -v konsole >/dev/null 2>&1; then
    echo "[*] Launching tmux viewer in Konsole"
    if konsole -e "${attach_cmd[@]}" >/dev/null 2>&1 & disown; then
      return 0
    fi
    echo "[!] Konsole launch failed; continuing without popup terminal"
  fi

  if is_gnome_session && command -v gnome-terminal >/dev/null 2>&1; then
    echo "[*] Launching tmux viewer in GNOME Terminal"
    if gnome-terminal -- "${attach_cmd[@]}" >/dev/null 2>&1 & disown; then
      return 0
    fi
    echo "[!] GNOME Terminal launch failed; continuing without popup terminal"
  fi

  if command -v x-terminal-emulator >/dev/null 2>&1; then
    echo "[*] Launching tmux viewer in x-terminal-emulator"
    if x-terminal-emulator -e "${attach_cmd[@]}" >/dev/null 2>&1 & disown; then
      return 0
    fi
    echo "[!] x-terminal-emulator launch failed; continuing without popup terminal"
  fi

  echo "[!] No supported GUI terminal launched; attach manually with: tmux attach -t $SESSION"
  return 1
}



# Start tmux session with QEMU
# Kill any old session so new-session can succeed
tmux kill-session -t "$SESSION" 2>/dev/null || true
# Create a new detached tmux session
# have qemu boot using uefi
tmux new-session -d \
  -s "$SESSION" \
  -n "$WINDOW" \
  "qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -m 2048 \
    -cpu host \
    -smp 12 \
    -enable-kvm \
    -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
    -drive if=pflash,format=raw,file=$OVMF_VARS \
    -drive file=$DISK_IMG,format=qcow2,if=virtio \
    -serial mon:stdio \
    -nic user,model=virtio,mac=52:54:00:f6:2c:43 \
    -nographic; exec bash"

time_vm_start=$(date +%s)


# 2) Attach in another terminal
# TODO: Would be great for this to all stay in the original terminal but split screen
launch_tmux_viewer || true

wait_for_text() {
  local text="$1"
  local num_lines="${2:-20}"
  local delay="${3:-1}"

  echo "[*] Waiting for text: $text"
  while true; do
    OUTPUT=$(capture_recent_output "$num_lines")
    if echo "$OUTPUT" | grep -Fqi "$text"; then
      now=$(date +%s)
      echo "[*] Found text: $text +$((now - time_vm_start)) seconds"
      return 0
    fi
    sleep "$delay"
  done
}

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

unlock_disk() {
  local expect_custom_prompt="${1:-false}"

  if [[ "$expect_custom_prompt" == "true" ]]; then
    wait_for_text "$CUSTOM_LUKS_PROMPT_MARKER" 25 1
  fi

  wait_for_prompt_and_send "unlock disk luks-volume:" "$PASSPHRASE" 25 1
}

assert_initramfs_contains_custom_prompt() {
  echo "[*] Verifying custom prompt hook is packed into initramfs"
  tmux send-keys -t "$PANE" "lsinitramfs /boot/initrd.img-\$(uname -r) | grep -x '$CUSTOM_LUKS_PROMPT_SCRIPT_PATH'" Enter
  sleep 0.5
  OUTPUT=$(tmux capture-pane -p -S -200 -t "$PANE")
  if echo "$OUTPUT" | grep -q "$CUSTOM_LUKS_PROMPT_SCRIPT_PATH"; then
    echo "OK: custom LUKS prompt hook found in initramfs"
  else
    echo "ERROR: custom LUKS prompt hook missing from initramfs"
    exit 1
  fi
}

# wait for the shell to be ready
wait_for_ready() {
  local prompt=".*\\$\\s*"
  local num_lines=1
  local delay=0.1
  echo "[*] Waiting for prompt: $prompt"
  while true; do
    now=$(date +%s)
    PANE_HEIGHT=$(tmux display -p -t "$PANE" '#{pane_height}')
    NUM_LINES=1
    START_LINE=$((PANE_HEIGHT - NUM_LINES))
    OUTPUT=$(tmux capture-pane -p -S ${START_LINE} -E -  -t "$PANE")
    # use regex matching
    if echo "$OUTPUT" | grep -P -x "$prompt"; then
      now=$(date +%s)
      echo "terminal ready: +$((now - time_vm_start)) seconds"
      break
    fi
    sleep "$delay"
  done
}

echo "first boot for cloud-init config"

# Inject disk encryption passphrase
unlock_disk false

# Perform user login
wait_for_prompt_and_send "login:" "$USERNAME"
wait_for_prompt_and_send "Password:" "$PASSWORD"

wait_for_ready


# follow the cloud init log and wait for the finished line
tmux send-keys -t "$PANE" "watch -n 1 'grep \"finished\" /var/log/cloud-init-output.log'" Enter
# when finished exit the tail
wait_for_prompt_and_send "Cloud-init v\..* finished at .*" "q" 50
# exit the tail -f
tmux send-keys -t "$PANE" C-c

wait_for_ready
assert_initramfs_contains_custom_prompt

#
echo "looking for GRUB_CMDLINE_LINUX_DEFAULT"
tmux send-keys -t "$PANE" "cat /etc/default/grub " Enter
sleep 0.5
# capture the pane output
OUTPUT=$(tmux capture-pane -p -S -200 -t "$PANE")
# test for the line but don’t let grep’s exit kill the script
if echo "$OUTPUT" | grep -q "GRUB_CMDLINE_LINUX_DEFAULT="; then
  # 1) capture the exact line into DEFAULT_LINE
  DEFAULT_LINE=$(printf '%s\n' "$OUTPUT" | grep "GRUB_CMDLINE_LINUX_DEFAULT=")
  # 2) print that line
  echo "Found kernel cmdline: $DEFAULT_LINE"
  # 3) check if it contains 'resume='
  if [[ "$DEFAULT_LINE" == *resume=* ]]; then
    echo "OK: resume= is present in kernel parameters"
  else
    echo "WARNING: resume= not found in kernel parameters"
  fi

else
  echo "ERROR: could not find GRUB_CMDLINE_LINUX_DEFAULT line"
fi


wait_for_ready
# read -p "Press ENTER to reboot..."

# # reboot
echo "rebooting"
tmux send-keys -t "$PANE" "sudo reboot now" Enter

# watch boot and assert the custom prompt before unlocking
unlock_disk true

# Perform user login
wait_for_prompt_and_send "login:" "$USERNAME"
wait_for_prompt_and_send "Password:" "$PASSWORD"

# now we are logged back in

wait_for_ready

tmux send-keys -t "$PANE" "swapon --show " Enter
sleep 0.5

tmux send-keys -t "$PANE" "grep resume /proc/cmdline " Enter
sleep 0.5


# store something that will persist on hibernate but not reboot
tmux send-keys -t "$PANE" "echo 'magic-suspend-token645632' > /dev/shm/hibernation_check" Enter

# optional wait for enter
tmux send-keys -t "$PANE" "sudo systemctl hibernate" Enter



# TODO: how to check we are back at the host properly ??
sleep 20
# read -p "Press ENTER when qemu is done..."

#
wait_for_ready

# Now launch another VM instance
tmux send-keys -t "$SESSION:$WINDOW" "
qemu-system-x86_64 \\
  -machine q35,accel=kvm \\
  -m 2048 \\
  -cpu host \\
  -smp 12 \\
  -enable-kvm \\
  -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \\
  -drive if=pflash,format=raw,file=$OVMF_VARS \\
  -drive file=$DISK_IMG,format=qcow2,if=virtio \\
  -serial mon:stdio \\
  -nic user,model=virtio,mac=52:54:00:f6:2c:43 \\
  -nographic
" Enter

time_vm_start=$(date +%s)


unlock_disk true

sleep 10

# no login needed here will come back to the same place we left it
tmux send-keys -t "$PANE" Enter
wait_for_ready

echo "looking for magic-suspend-token"
tmux send-keys -t "$PANE" "cat /dev/shm/hibernation_check " Enter
sleep 0.5
# capture the pane output
OUTPUT=$(tmux capture-pane -p -S -200 -t "$PANE")
# test for the line but don’t let grep’s exit kill the script
if echo "$OUTPUT" | grep -q "magic-suspend-token645632"; then
  echo "found magic-suspend-token hibernation is WORKING !!!"
else
  echo "ERROR: could not find magic-suspend-token hibernation is NOT working"
  read -p "Press ENTER to exit"
fi
