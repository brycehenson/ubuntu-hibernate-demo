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


sudo cloud-init schema --config-file cloud_config/user-data

# setup a cloud-config iso file
xorriso -as mkisofs \
  -r -J -joliet-long \
  -V CIDATA \
  -o "$CLOUDISO" \
  cloud_config/



# Kill any old session so new-session can succeed
tmux kill-session -t "$SESSION" 2>/dev/null || true

#  -drive file="$CLOUDISO",media=cdrom,index=1 \

# 1) Create tmux session running QEMU
# Create a new detached tmux session
tmux new-session -d \
  -s "$SESSION" \
  -n "$WINDOW" \
  "qemu-system-x86_64 -m 2048 -enable-kvm \
  -drive file=$DISK_IMG,format=qcow2 \
  -serial mon:stdio \
  -nographic; exec bash"

time_vm_start=$(date +%s)

# Debug: verify session & window exist
tmux list-sessions
tmux list-windows -t "$SESSION"

# 2) Optionally attach in another terminal
gnome-terminal -- tmux attach-session -t "$SESSION" & disown

# sleep 1

# # 3) Watch & interact
# # inject disk enc passphrase
# echo "[Primary] watching tmux pane $PANE"
# while true; do
#   OUTPUT=$(tmux capture-pane  -p -S -10 -t "$PANE")
#   # echo "$OUTPUT"
#   if echo "$OUTPUT" | grep -qiF 'Please unlock disk luks-volume:'; then
#     now=$(date +%s)
#     echo "[*] sending passphrase +$((now - time_vm_start)) seconds"
#     tmux send-keys -t "$PANE" "pass" Enter
#     break
#   fi
#   sleep 1
# done

# # user login
# # user login
# echo "[Primary] watching tmux pane $PANE"
# while true; do
#   OUTPUT=$(tmux capture-pane  -p -S -20 -t "$PANE")
#   # echo "$OUTPUT"
#   if echo "$OUTPUT" | grep -qiF 'login:'; then
#     sleep 1
#     now=$(date +%s)
#     echo "[*] sending login +$((now - time_vm_start)) seconds"
#     tmux send-keys -t "$PANE" "ubuntu" Enter
#     sleep 0.5
#     tmux send-keys -t "$PANE" "pass" Enter
#     sleep 0.5
#     break
#   fi
#   sleep 5
# done

# # wait for cloud-init to finish
# # TODO: replace this with watching the cloud init log for the finished signal
# sleep 30
# echo "looking for GRUB_CMDLINE_LINUX_DEFAULT"
# tmux send-keys -t "$PANE" "cat /etc/default/grub " Enter
# sleep 0.5
# # capture the pane output
# OUTPUT=$(tmux capture-pane -p -S -200 -t "$PANE")

# # test for the line but don’t let grep’s exit kill the script
# if echo "$OUTPUT" | grep -q "GRUB_CMDLINE_LINUX_DEFAULT="; then
#   # 1) capture the exact line into DEFAULT_LINE
#   DEFAULT_LINE=$(printf '%s\n' "$OUTPUT" | grep "GRUB_CMDLINE_LINUX_DEFAULT=")
#   # 2) print that line
#   echo "Found kernel cmdline: $DEFAULT_LINE"
#   # 3) check if it contains 'resume='
#   if [[ "$DEFAULT_LINE" == *resume=* ]]; then
#     echo "OK: resume= is present in kernel parameters"
#   else
#     echo "WARNING: resume= not found in kernel parameters"
#   fi

# else
#   echo "ERROR: could not find GRUB_CMDLINE_LINUX_DEFAULT line"
# fi


# sleep 5

# # reboot
# echo "rebooting"
# tmux send-keys -t "$PANE" "sudo reboot now" Enter

# watch boot and pass paraphrase

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

# now we are logged back in

tmux send-keys -t "$PANE" "swapon --show " Enter
sleep 0.5

tmux send-keys -t "$PANE" "grep resume /proc/cmdline " Enter
sleep 0.5


# TODO: send command to store something that will persist on hibernate but not reboot

# optional wait for enter
# read -p "Press ENTER to hibernate..."

tmux send-keys -t "$PANE" "sudo systemctl hibernate" Enter


#TODO instead of sleep check that the previous command has exited
sleep 40


# Now launch another VM instance


tmux send-keys -t "$SESSION:$WINDOW" "
qemu-system-x86_64 \\
  -m 2048 \\
  -enable-kvm \\
  -drive file=$DISK_IMG,format=qcow2 \\
  -serial mon:stdio \\
  -nographic
" Enter

time_vm_start=$(date +%s)



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
