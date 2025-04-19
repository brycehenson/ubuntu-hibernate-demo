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

# 1) Launch GNOME Terminal to monitor serial (Terminal 2)
gnome-terminal -- bash -c "
  while [ ! -S '$SOCK' ]; do sleep 1; clear; echo '[*] Waiting for QEMU to open socket: $SOCK'; date ; done;
  echo '[*] Serial ready—connecting now';
  exec socat -,raw,echo=0 UNIX-CONNECT:$SOCK
" & disown

# # 2) Launch QEMU in THIS terminal (Terminal 1)
# qemu-system-x86_64 \
#   -m 2048 \
#   -enable-kvm \
#   -drive file="$DISK_IMG",format=qcow2 \
#   -chardev "socket,path=$SOCK,server=on,wait=off,mux=on,id=char0" \
#   -serial chardev:char0 \
#   -mon chardev=char0,mode=readline \
#   -nographic


# 3) Start QEMU in background, serial → the muxed socket
qemu-system-x86_64 \
  -m 2048 \
  -enable-kvm \
  -drive file="$DISK_IMG",format=qcow2 \
  -chardev "socket,path=$SOCK,server=on,wait=off,mux=on,id=char0" \
  -serial chardev:char0 \
  -nographic &

QEMU_PID=$!

# 4) In this (original) terminal, wait then attach via socat
echo "[Primary] waiting for socket to appear..."
until [ -S "$SOCK" ] ; do sleep 0.1; done

echo "[Primary] socket up — attaching console..."
socat -,raw,echo=0 UNIX-CONNECT:"$SOCK"