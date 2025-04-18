#!/usr/bin/env bash
set -euo pipefail


DISK_IMG="${HOME}/vm/ubuntu-fde-hibernate/vm-disk.qcow2"




echo "[*] Starting QEMU VM..."
qemu-system-x86_64 \
  -m 8000 \
  -cpu host \
  -smp 12 \
  -enable-kvm \
  -drive file="$DISK_IMG",format=qcow2 \
  -boot d \
  -serial mon:stdio \
  -net none
#    -nographic 
