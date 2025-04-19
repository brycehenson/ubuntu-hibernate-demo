#!/usr/bin/env bash
set -euo pipefail


DISK_IMG="${HOME}/vm/ubuntu-fde-hibernate/vm-disk.qcow2"




echo "[*] Starting QEMU VM..."
qemu-system-x86_64 \
  -m 5000 \
  -cpu host \
  -smp 12 \
  -enable-kvm \
  -drive file="$DISK_IMG",format=qcow2 \
  -boot d \

  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -serial mon:stdio \
  -nographic \
