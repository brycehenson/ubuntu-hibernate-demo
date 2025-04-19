#!/usr/bin/env bash
set -euo pipefail


DISK_IMG="${HOME}/vm/ubuntu-fde-hibernate/vm-disk.qcow2"

SOCK=$(mktemp -u /tmp/qemu-serial-XXXXXX.sock)

cleanup() {
  echo "[*] Cleaning up socket: $SOCK"
  rm -f "$SOCK"
}
trap cleanup EXIT

echo "[*] Using socket: $SOCK"

# 1) Launch GNOME Terminal to monitor serial (Terminal 2)
gnome-terminal -- bash -c "
  echo '[*] Waiting for QEMU to open socket: $SOCK';
  while [ ! -S '$SOCK' ]; do sleep 0.1; done;
  echo '[*] Serial ready—connecting now';
  exec socat -,raw,echo=0 UNIX-CONNECT:$SOCK
" & disown

# 2) Launch QEMU in THIS terminal (Terminal 1)
qemu-system-x86_64 \
  -m 2048 \
  -enable-kvm \
  -drive file=\"$DISK_IMG\",format=qcow2 \
  -chardev socket,path=\"$SOCK\",server,nowait,mux=on,id=char0 \
  -serial chardev:char0 \
  -mon chardev=char0,mode=readline \
  -nographic