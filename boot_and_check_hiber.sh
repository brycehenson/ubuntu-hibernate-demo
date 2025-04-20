#!/usr/bin/env bash
set -euo pipefail


DISK_IMG="${HOME}/vm/ubuntu-fde-hibernate/vm-disk.qcow2"
SESSION="vmconsole"
WINDOW="1"
PANE="${SESSION}:1"



TMPDIR="$(mktemp -d)"
CLOUDISO="${TMPDIR}/cloud.iso"


QEMU_PID=""
cleanup() {
  echo "[*] Cleaning up…"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
   sudo rm -rf "$TMPDIR"
}
trap cleanup EXIT



# setup a cloud-config iso file
xorriso -as mkisofs \
  -r -J -joliet-long \
  -V CIDATA \
  -o "$CLOUDISO" \
  cloud_config/



# Kill any old session so new-session can succeed
tmux kill-session -t "$SESSION" 2>/dev/null || true


# 1) Create tmux session running QEMU
tmux new-session -d \
  -s "$SESSION" \
  -n "$WINDOW" \
  "qemu-system-x86_64 -m 2048 -enable-kvm \
  -drive file=$DISK_IMG,format=qcow2 \
  -drive file="$CLOUDISO",media=cdrom,index=1 \
  -serial mon:stdio \
  -nographic
  "


time_vm_start=$(date +%s)

# Debug: verify session & window exist
tmux list-sessions
tmux list-windows -t "$SESSION"

# 2) Optionally attach in another terminal
gnome-terminal -- tmux attach-session -t "$SESSION" & disown

sleep 1

# 3) Watch & interact
# inject disk enc passphrase
echo "[Primary] watching tmux pane $PANE"
while true; do
  OUTPUT=$(tmux capture-pane  -p -S -10 -t "$PANE")
  # echo "$OUTPUT"
  if echo "$OUTPUT" | grep -qiF 'Please unlock disk luks-volume:'; then
    now=$(date +%s)
    echo "[*] sending passphrase +$((now - time_vm_start)) seconds"
    tmux send-keys -t "$PANE" "pass" Enter
    break
  fi
  sleep 1
done

# user login
# user login
echo "[Primary] watching tmux pane $PANE"
while true; do
  OUTPUT=$(tmux capture-pane  -p -S -20 -t "$PANE")
  # echo "$OUTPUT"
  if echo "$OUTPUT" | grep -qiF 'login:'; then
    sleep 1
    now=$(date +%s)
    echo "[*] sending login +$((now - time_vm_start)) seconds"
    tmux send-keys -t "$PANE" "ubuntu" Enter
    sleep 0.5
    tmux send-keys -t "$PANE" "pass" Enter
    sleep 0.5
    break
  fi
  sleep 5
done


sleep 3
echo "looking for GRUB_CMDLINE_LINUX_DEFAULT"
tmux send-keys -t "$PANE" "cat /etc/default/grub " Enter
sleep 0.5
# capture the pane output
OUTPUT=$(tmux capture-pane -p -t "$PANE")

# test for the line but don’t let grep’s exit kill the script
if echo "$OUTPUT" | grep -q "GRUB_CMDLINE_LINUX_DEFAULT="; then
  if ! echo "$OUTPUT" | grep -q "resume="; then
    echo "WARNING: resume= not found in kernel parameters"
    echo "  $DEFAULT_LINE"
  fi
else
  echo "ERROR: could not find GRUB_CMDLINE_LINUX_DEFAULT line"
fi


read -p "Press ENTER to shutdown..."

tmux send-keys -t "$PANE" "shutdown now " Enter


sleep 5