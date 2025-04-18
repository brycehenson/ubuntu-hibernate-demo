#!/usr/bin/env bash
set -euo pipefail

ISO_PATH="${HOME}/Downloads/ubuntu-24.04.2-live-server-amd64.iso"
NOCLOUD_ISO="working/nocloud.iso"
DISK_IMG="${HOME}/vm/ubuntu-fde-hibernate/vm-disk.qcow2"
OUT_ISO="${HOME}/vm/ubuntu-fde-hibernate/ubuntu-autoinstall-patched.iso"


echo "create nocloud iso"
cloud-localds --filesystem=iso $NOCLOUD_ISO autoinstall/user-data autoinstall/meta-data


TMPDIR="$(mktemp -d)"
MOUNT_DIR="${TMPDIR}/iso_mount"
WORKDIR="${TMPDIR}/extracted"

cleanup() {
    echo "[*] Cleaning up..."
    sudo umount "$MOUNT_DIR" || true
    sudo rm -rf "$TMPDIR"
    sudo rm -rf "$NOCLOUD_ISO"
}
trap cleanup EXIT

echo "[*] Creating temp dirs..."
mkdir -p "$MOUNT_DIR" "$WORKDIR"

echo "[*] Mounting ISO from $ISO_PATH"
sudo mount -o loop "$ISO_PATH" "$MOUNT_DIR"

echo "[*] Copying ISO contents to working dir..."
sudo rsync -a "$MOUNT_DIR/" "$WORKDIR/"

sudo umount "$MOUNT_DIR"

echo "[*] Patching grub config..."
GRUB_CFG="$WORKDIR/boot/grub/grub.cfg"
echo "grub cfg"
cat $GRUB_CFG > working/grub_before.cfg
echo "\n"
# autoinstall ds=nocloud;s=\/cdrom\/ 
sudo sed -i 's|---| autoinstall ds=nocloud;d=/dev/sr1 console=ttyS0,115200n8 console=tty0 earlyprintk=ttyS0,115200 debug ---|' "$GRUB_CFG"
sudo sed -i 's/^set timeout=.*/set timeout=3/' "$GRUB_CFG"
cat $GRUB_CFG > working/grub_after.cfg


echo "[*] Rebuilding ISO: $OUT_ISO"
xorriso -as mkisofs \
  -r -V "UBUNTU_AUTOINSTALL" \
  -o "$OUT_ISO" \
  -J -l \
  -b boot/grub/i386-pc/eltorito.img \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
  "$WORKDIR"


echo "[✓] Output ISO written to: $OUT_ISO"


echo "[*] Starting QEMU VM..."
qemu-system-x86_64 \
  -m 4096 \
  -smp 2 \
  -enable-kvm \
  -drive file="$OUT_ISO",media=cdrom,index=0 \
  -drive file="$NOCLOUD_ISO",media=cdrom,index=1 \
  -drive file="$DISK_IMG",format=qcow2 \
  -boot d \
  -serial mon:stdio \
  -net nic -net user \
#    -nographic 
