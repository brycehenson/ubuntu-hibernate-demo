#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

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
SESSION_BASE="vmconsole"
SESSION_SUFFIX="$(printf '%04d' "$((RANDOM % 10000))")"
SESSION="${SESSION_BASE}-${SESSION_SUFFIX}"
WINDOW="1"
PANE="${SESSION}:${WINDOW}"
PASSPHRASE="pass"
USERNAME="ubuntu"
PASSWORD="pass"
CUSTOM_LUKS_PROMPT_MARKER="Hi there friend, thanks for finding my laptop !"
CUSTOM_LUKS_PROMPT_SCRIPT_PATH="/lib/cryptsetup/scripts/custom-askpass-banner"
CUSTOM_LUKS_PROMPT_INITRAMFS_PATH_REGEX='(usr/)?lib/cryptsetup/scripts/custom-askpass-banner'
CUSTOM_LUKS_PROMPT_CRYPTTAB_OK="__CUSTOM_LUKS_PROMPT_CRYPTTAB_OK__"
CUSTOM_LUKS_PROMPT_CRYPTTAB_MISSING="__CUSTOM_LUKS_PROMPT_CRYPTTAB_MISSING__"
CUSTOM_LUKS_PROMPT_HOOK_OK="__CUSTOM_LUKS_PROMPT_HOOK_PRESENT__"
CUSTOM_LUKS_PROMPT_HOOK_MISSING="__CUSTOM_LUKS_PROMPT_HOOK_MISSING__"
CUSTOM_LUKS_PROMPT_DIAG_BEGIN="__CUSTOM_LUKS_PROMPT_DIAG_BEGIN__"
CUSTOM_LUKS_PROMPT_DIAG_END="__CUSTOM_LUKS_PROMPT_DIAG_END__"
ONLY_ONE_SWAP_OK="__ONLY_ONE_SWAP_OK__"
ONLY_ONE_SWAP_BAD="__ONLY_ONE_SWAP_BAD__"
SWAP_SHOW_BEGIN="__SWAP_SHOW_BEGIN__"
SWAP_SHOW_END="__SWAP_SHOW_END__"
TMPDIR="$(mktemp -d)"
CLOUDISO="${TMPDIR}/cloud.iso"
qemu_launch_id=1

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
    -nographic; \
    status=\$?; \
    echo \"[*] QEMU exited with status \$status [launch=$qemu_launch_id]\"; \
    exec bash"
#     -nic user,model=virtio,mac=52:54:00:f6:2c:43 \
time_vm_start=$(date +%s)


# 2) Attach in another terminal
# TODO: Would be great for this to all stay in the original terminal but split screen
launch_tmux_viewer || true

unlock_disk() {
  local expect_custom_prompt="${1:-false}"

  if [[ "$expect_custom_prompt" == "true" ]]; then
    wait_for_custom_luks_prompt
  fi

  wait_for_prompt_and_send "$PANE" "unlock disk luks-volume:" "$PASSPHRASE" "$time_vm_start" 25 1 30
}

dump_recent_pane_scrollback() {
  echo "[!] Recent VM console scrollback:"
  tmux_capture_scrollback "$PANE" -200
}

dump_active_swap_entries() {
  local output
  local swap_output

  echo "[*] Collecting clean active swap listing"
  tmux send-keys -t "$PANE" "printf '%s\n' '$SWAP_SHOW_BEGIN'; swapon --show; printf '%s\n' '$SWAP_SHOW_END'" Enter
  wait_for_ready
  output=$(tmux_capture_scrollback "$PANE" -200)
  swap_output=$(printf '%s\n' "$output" | sed -n "/$SWAP_SHOW_BEGIN/,/$SWAP_SHOW_END/p" | sed "1d;\$d")
  if [[ -n "$swap_output" ]]; then
    echo "[!] Active swap entries:"
    printf '%s\n' "$swap_output"
  else
    echo "[!] Active swap entries could not be captured cleanly."
    dump_recent_pane_scrollback
  fi
}

dump_initramfs_custom_prompt_diagnostics() {
  local output
  local diagnostics

  echo "[*] Collecting initramfs diagnostics for the custom LUKS prompt"
  tmux send-keys -t "$PANE" "tmpdir=\$(mktemp -d) && initrd=/boot/initrd.img-\$(uname -r) && printf '%s\n' '$CUSTOM_LUKS_PROMPT_DIAG_BEGIN' && printf 'kernel=%s\n' \"\$(uname -r)\" && printf '%s\n' '-- /etc/crypttab entry --' && grep -nE '^luks-volume[[:space:]]' /etc/crypttab || true && printf '%s\n' '-- lsinitramfs matches --' && lsinitramfs \"\$initrd\" | grep -E 'cryptroot/crypttab|custom-askpass-banner|lib/cryptsetup/(askpass|scripts)' || true && if command -v unmkinitramfs >/dev/null 2>&1; then unmkinitramfs \"\$initrd\" \"\$tmpdir\" >/dev/null 2>&1 || true; printf '%s\n' '-- embedded cryptroot/crypttab --' && if [ -f \"\$tmpdir/main/cryptroot/crypttab\" ]; then grep -nE '^luks-volume[[:space:]]' \"\$tmpdir/main/cryptroot/crypttab\" || true; else printf '%s\n' 'embedded cryptroot/crypttab missing'; fi; else printf '%s\n' 'unmkinitramfs not available'; fi; rm -rf \"\$tmpdir\"; printf '%s\n' '$CUSTOM_LUKS_PROMPT_DIAG_END'" Enter
  wait_for_ready
  output=$(tmux_capture_scrollback "$PANE" -400)
  diagnostics=$(printf '%s\n' "$output" | sed -n "/$CUSTOM_LUKS_PROMPT_DIAG_BEGIN/,/$CUSTOM_LUKS_PROMPT_DIAG_END/p")
  if [[ -n "$diagnostics" ]]; then
    printf '%s\n' "$diagnostics"
  else
    echo "[!] Initramfs diagnostics were requested, but the marker block was not found."
    dump_recent_pane_scrollback
  fi
}

wait_for_custom_luks_prompt() {
  local output
  local now
  local wait_started_s

  echo "[*] Waiting for the custom LUKS banner before the unlock prompt"
  wait_started_s=$(date +%s)
  while true; do
    now=$(date +%s)
    output=$(tmux_capture_scrollback "$PANE" -200)
    if printf '%s\n' "$output" | grep -Fqi "$CUSTOM_LUKS_PROMPT_MARKER"; then
      echo "[*] Found custom LUKS banner +$((now - time_vm_start)) seconds"
      return 0
    fi
    if printf '%s\n' "$output" | grep -Fqi "Please unlock disk luks-volume:"; then
      echo "ERROR: unlock prompt appeared before the custom LUKS banner" >&2
      dump_recent_pane_scrollback
      exit 1
    fi
    if (( now - wait_started_s >= 30 )); then
      echo "ERROR: timed out waiting for the custom LUKS banner" >&2
      dump_recent_pane_scrollback
      exit 1
    fi
    sleep 1
  done
}

assert_initramfs_contains_custom_prompt() {
  local output

  echo "[*] Verifying custom prompt keyscript is packed into initramfs"
  tmux send-keys -t "$PANE" "if lsinitramfs /boot/initrd.img-\$(uname -r) | grep -qxE '$CUSTOM_LUKS_PROMPT_INITRAMFS_PATH_REGEX'; then printf '%s\n' '$CUSTOM_LUKS_PROMPT_HOOK_OK'; else printf '%s\n' '$CUSTOM_LUKS_PROMPT_HOOK_MISSING'; fi" Enter
  wait_for_ready
  output=$(tmux_capture_scrollback "$PANE")
  if printf '%s\n' "$output" | grep -Fxq "$CUSTOM_LUKS_PROMPT_HOOK_OK"; then
    echo "OK: custom LUKS prompt keyscript found in initramfs"
  elif printf '%s\n' "$output" | grep -Fxq "$CUSTOM_LUKS_PROMPT_HOOK_MISSING"; then
    echo "ERROR: custom LUKS prompt keyscript missing from initramfs"
    dump_initramfs_custom_prompt_diagnostics
    exit 1
  else
    echo "ERROR: could not determine whether the custom LUKS prompt keyscript is packed into initramfs"
    dump_recent_pane_scrollback
    exit 1
  fi
}

assert_crypttab_contains_custom_prompt_keyscript() {
  local output

  echo "[*] Verifying /etc/crypttab includes the custom prompt keyscript"
  tmux send-keys -t "$PANE" "if grep -E '^luks-volume[[:space:]]' /etc/crypttab | grep -Fq 'keyscript=$CUSTOM_LUKS_PROMPT_SCRIPT_PATH'; then printf '%s\n' '$CUSTOM_LUKS_PROMPT_CRYPTTAB_OK'; else printf '%s\n' '$CUSTOM_LUKS_PROMPT_CRYPTTAB_MISSING'; fi" Enter
  wait_for_ready
  output=$(tmux_capture_scrollback "$PANE")
  if printf '%s\n' "$output" | grep -Fxq "$CUSTOM_LUKS_PROMPT_CRYPTTAB_OK"; then
    echo "OK: /etc/crypttab contains the custom LUKS prompt keyscript"
  elif printf '%s\n' "$output" | grep -Fxq "$CUSTOM_LUKS_PROMPT_CRYPTTAB_MISSING"; then
    echo "ERROR: /etc/crypttab does not contain the custom LUKS prompt keyscript"
    dump_recent_pane_scrollback
    exit 1
  else
    echo "ERROR: could not determine whether /etc/crypttab contains the custom LUKS prompt keyscript"
    dump_recent_pane_scrollback
    exit 1
  fi
}

assert_only_one_swap_active() {
  local output

  echo "[*] Verifying there is exactly one active swap entry"
  tmux send-keys -t "$PANE" "swap_lines=\$(swapon --show=NAME --noheadings | sed '/^[[:space:]]*$/d'); swap_count=\$(printf '%s\n' \"\$swap_lines\" | sed '/^[[:space:]]*$/d' | wc -l); printf '%s\n' \"\$swap_lines\"; if [ \"\$swap_count\" -eq 1 ]; then printf '%s\n' '$ONLY_ONE_SWAP_OK'; else printf '%s\n' '$ONLY_ONE_SWAP_BAD'; fi" Enter
  wait_for_ready
  output=$(tmux_capture_scrollback "$PANE")
  if printf '%s\n' "$output" | grep -Fxq "$ONLY_ONE_SWAP_OK"; then
    echo "OK: exactly one swap entry is active"
  elif printf '%s\n' "$output" | grep -Fxq "$ONLY_ONE_SWAP_BAD"; then
    echo "ERROR: expected exactly one active swap entry"
    dump_active_swap_entries
    dump_recent_pane_scrollback
    exit 1
  else
    echo "ERROR: could not determine how many swap entries are active"
    dump_active_swap_entries
    dump_recent_pane_scrollback
    exit 1
  fi
}

# wait for the shell to be ready
wait_for_ready() {
  local prompt=".*\\$\\s*"
  local num_lines=1
  local delay=0.1
  local output
  local now

  echo "[*] Waiting for prompt: $prompt"
  while true; do
    now=$(date +%s)
    output=$(tmux_capture_recent_output "$PANE" "$num_lines")
    # use regex matching
    if echo "$output" | grep -P -x "$prompt"; then
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
wait_for_prompt_and_send "$PANE" "login:" "$USERNAME" "$time_vm_start" 0
wait_for_prompt_and_send "$PANE" "Password:" "$PASSWORD" "$time_vm_start" 0

wait_for_ready


# follow the cloud init log and wait for the finished line
tmux send-keys -t "$PANE" "watch -n 1 'grep \"finished\" /var/log/cloud-init-output.log'" Enter
# when finished exit the tail
wait_for_prompt_and_send "$PANE" "Cloud-init v\..* finished at .*" "q" "$time_vm_start" 0
# exit the tail -f
tmux send-keys -t "$PANE" C-c

wait_for_ready
assert_crypttab_contains_custom_prompt_keyscript
assert_initramfs_contains_custom_prompt
wait_for_ready
tmux send-keys -t "$PANE"  Enter
sleep 0.5
#
echo "looking for GRUB_CMDLINE_LINUX_DEFAULT"
tmux send-keys -t "$PANE" "cat /etc/default/grub " Enter
sleep 0.5
# capture the pane output
OUTPUT=$(tmux_capture_scrollback "$PANE")
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
  read 
fi


wait_for_ready
# read -p "Press ENTER to reboot..."

# # reboot
echo "rebooting"
tmux send-keys -t "$PANE" "sudo reboot now" Enter

# watch boot and assert the custom prompt before unlocking
unlock_disk true

# Perform user login
wait_for_prompt_and_send "$PANE" "login:" "$USERNAME" "$time_vm_start"
wait_for_prompt_and_send "$PANE" "Password:" "$PASSWORD" "$time_vm_start"

# now we are logged back in

wait_for_ready

tmux send-keys -t "$PANE" "swapon --show " Enter
sleep 0.5
assert_only_one_swap_active

tmux send-keys -t "$PANE" "grep resume /proc/cmdline " Enter
sleep 0.5


# store something that will persist on hibernate but not reboot
tmux send-keys -t "$PANE" "echo 'magic-suspend-token645632' > /dev/shm/hibernation_check" Enter

# optional wait for enter
hibernate_start_time=$(date +%s)
tmux send-keys -t "$PANE" "sudo systemctl hibernate" Enter

wait_for_text "$PANE" "QEMU exited with status" "$hibernate_start_time" 0 0.5 120
wait_for_quiet_seconds "$PANE" 2 0.5

# Now launch another VM instance
qemu_launch_id=$((qemu_launch_id + 1))
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
  -nographic; \\
  status=\\\$?; \\
  echo \"[*] QEMU exited with status \\\$status [launch=$qemu_launch_id]\"; \\
  exec bash
" Enter
#   -nic user,model=virtio,mac=52:54:00:f6:2c:43 \\

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
OUTPUT=$(tmux_capture_scrollback "$PANE")
# test for the line but don’t let grep’s exit kill the script
if echo "$OUTPUT" | grep -q "magic-suspend-token645632"; then
  echo "found magic-suspend-token hibernation is WORKING !!!"
else
  echo "ERROR: could not find magic-suspend-token hibernation is NOT working"
  read -p "Press ENTER to exit"
fi

echo "done shutdown"
tmux send-keys -t "$PANE" "sudo shutdown now" Enter

wait_for_text "$PANE" "QEMU exited with status" "$hibernate_start_time" 0 0.5 120
