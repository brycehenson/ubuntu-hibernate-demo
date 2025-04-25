#!/usr/bin/env bash
set -euo pipefail

ISO_URL="https://releases.ubuntu.com/noble/ubuntu-24.04.2-live-server-amd64.iso"
AUTOINSTALL_DIR="autoinstall"
ISO_PATH="/home/bryce/Downloads/ubuntu-24.04.2-live-server-amd64.iso"
NOCLOUD_ISO="working/nocloud.iso"
DISK_IMG="/home/bryce/vm/ubuntu-fde-hibernate/vm-disk.qcow2"
OUT_ISO="/home/bryce/vm/ubuntu-fde-hibernate/ubuntu-autoinstall-patched.iso"



sudo cloud-init schema --config-file $AUTOINSTALL_DIR/user-data

echo "create nocloud iso"
cloud-localds --filesystem=iso $NOCLOUD_ISO $AUTOINSTALL_DIR/user-data $AUTOINSTALL_DIR/meta-data

if [ -f "$ISO_PATH" ]; then
  echo "[✓] ISO already exists."
else
  echo "[*] ISO not found. Downloading..."
  wget --show-progress -O "$ISO_PATH" "$ISO_URL"
  echo "[✓] Download complete: $ISO_PATH"
fi

# creating disk
if [ -f "$DISK_IMG" ]; then
  echo "[*] Deleting existing disk image at $DISK_IMG"
  rm -f "$DISK_IMG"
fi
qemu-img create -f qcow2 $DISK_IMG 20G

chmod a+rw $DISK_IMG


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

start=$(date +%s)

# To get ubuntu to user autoinstall we patch the iso
# in order to change the grub config

echo "[*] Creating temp dirs..."
mkdir -p "$MOUNT_DIR" "$WORKDIR"

echo "[*] Mounting ISO from $ISO_PATH"
sudo mount -o loop "$ISO_PATH" "$MOUNT_DIR"

echo "[*] Copying ISO contents to working dir..."
sudo rsync -a "$MOUNT_DIR/" "$WORKDIR/"

sudo umount "$MOUNT_DIR"


echo "[*] Patching grub config..."
GRUB_CFG="$WORKDIR/boot/grub/grub.cfg"
cat $GRUB_CFG > working/before_changes_grub.cfg

# here change the grub config
# setup the system to use the serial terminal
# setup autoinstall note that we have to escape the semicolon
sudo sed -i 's|---| console=ttyS0 earlyprintk=ttyS0  autoinstall  ds=nocloud\;d=/dev/sr1 ---|' "$GRUB_CFG"
sudo sed -i 's/^set timeout=.*/set timeout=1/' "$GRUB_CFG"
cat $GRUB_CFG > working/after_changes_grub.cfg


# change this other grub config to, note sure if its needed
GRUB_CFG="$WORKDIR/boot/grub/loopback.cfg"
cat $GRUB_CFG > working/before_changes_loopback.cfg
# here change the grub config
sudo sed -i 's|---| console=ttyS0 earlyprintk=ttyS0  autoinstall ds=nocloud\;d=/dev/sr1  ---|' "$GRUB_CFG"
sudo sed -i 's/^set timeout=.*/set timeout=1/' "$GRUB_CFG"
cat $GRUB_CFG > working/after_changes_loopback.cfg


# now we build an iso that we will use
echo "[*] Rebuilding ISO: $OUT_ISO"
xorriso -as mkisofs \
  -r -V "UBUNTU_AUTOINSTALL" \
  -o "$OUT_ISO" \
  -J -l \
  -b boot/grub/i386-pc/eltorito.img \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
  "$WORKDIR"


echo "[✓] Output ISO written to: $OUT_ISO"

# pkill -f qemu-system

echo "[*] Starting QEMU VM..."
qemu-system-x86_64 \
  -m 5000 \
  -cpu host \
  -smp 12 \
  -enable-kvm \
  -drive file="$OUT_ISO",media=cdrom,index=0 \
  -drive file="$NOCLOUD_ISO",media=cdrom,index=1 \
  -drive file="$DISK_IMG",format=qcow2 \
  -boot d \
  -serial mon:stdio \
  -net none \
  -nographic \
  -no-reboot
# dont allow the vm to reboot so we catch it rebooting after install


end=$(date +%s)
echo ">>>> runtime $((end - start)) seconds"
