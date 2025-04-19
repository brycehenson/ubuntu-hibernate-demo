#!/usr/bin/env bash
set -euo pipefail


DISK_IMG="${HOME}/vm/ubuntu-fde-hibernate/vm-disk.qcow2"

SOCK=$(mktemp -u /tmp/qemu-serial-XXXXXX.sock)

QEMU_PID=""
cleanup() {
  echo "[*] Cleaning up…"
  if [[ -n "$QEMU_PID" ]] then
    echo "[*] Killing QEMU (pid $QEMU_PID)"
    kill "$QEMU_PID"
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  rm -f "$SOCK"
}
trap cleanup EXIT

echo "[*] Using socket: $SOCK"

# 3) Start QEMU in background,
qemu-system-x86_64 \
  -m 2048 \
  -enable-kvm \
  -drive file="$DISK_IMG",format=qcow2 \
  -chardev socket,path=$SOCK,server=on,wait=on,id=serial0 \
  -serial chardev:serial0 \
  -nographic \
  -monitor unix:/tmp/qemu-monitor.sock,server,nowait \
    > /tmp/qemu.out 2>&1 &

QEMU_PID=$!

echo "after qemu"


# Step 1: Create a virtual serial cable
socat PTY,link=/tmp/term1,raw,echo=0 PTY,link=/tmp/term2,raw,echo=0 &
SOCAT_PTY_PID=$!

echo "after socat 2"
# 4) In this (original) terminal, wait then attach via socat
echo "[Primary] waiting for socket to appear..."
until [ -S "$SOCK" ] ; do sleep 0.1; echo "waiting"; date; done

# Step 2: Bridge one end to the backend socket
socat UNIX-CONNECT:$SOCK /tmp/term1,raw,echo=0 &
SOCAT_PTY_PID2=$!

# 1) Launch GNOME Terminal to monitor serial (Terminal 2)
gnome-terminal -- bash -c "
  echo '[*] Connecting to PTY...';
  exec socat -,raw,echo=0 /tmp/term2
" & disown

echo "[Primary] socket up — attaching console..."
socat -,raw,echo=0,ignoreeof,escape=0x1C /tmp/term2