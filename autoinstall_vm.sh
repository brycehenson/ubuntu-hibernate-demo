#!/usr/bin/env bash
set -euo pipefail

USER_HOME=$(eval echo "~$SUDO_USER")

ISO_URL="https://releases.ubuntu.com/25.04/ubuntu-25.04-live-server-amd64.iso"
AUTOINSTALL_DIR="autoinstall"
ISO_PATH="${USER_HOME}/Downloads/ubuntu-25.04-live-server-amd64.iso"
NOCLOUD_ISO="working/nocloud.iso"
mkdir -p working

VM_DIR="${USER_HOME}/vm/ubuntu-demo"
DISK_IMG="${VM_DIR}/vm-disk.qcow2"
OUT_ISO="${VM_DIR}/ubuntu-autoinstall-patched.iso"
mkdir -p "$VM_DIR"


# Override these if your OVMF firmware lives elsewhere
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

# validation of user-data

sudo cloud-init schema --config-file $AUTOINSTALL_DIR/user-data
yamllint -d "{extends: default, rules: {line-length: disable}}" $AUTOINSTALL_DIR/user-data
python3 check_storage_config.py

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


TMPDIR="$(mktemp -d -p /var/tmp)"
MOUNT_DIR="${TMPDIR}/iso_mount"
WORKDIR="${TMPDIR}/extracted"
OVMF_VARS="${TMPDIR}/OVMF_VARS.fd"

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

if [[ -z "${OVMF_CODE:-}" ]]; then
  OVMF_CODE="${DEFAULT_OVMF_CODE[0]}"
fi

if [[ ! -r "$OVMF_CODE" ]]; then
  cat <<EOF >&2
[!] OVMF_CODE firmware missing or unreadable at: $OVMF_CODE
    Checked candidates: ${DEFAULT_OVMF_CODE[*]}
    Install the 'ovmf' package (e.g. sudo apt install ovmf) or set OVMF_CODE to the correct path.
    On some systems the file is named OVMF_CODE_4M.fd.
EOF
  exit 1
fi

if [[ -z "${OVMF_VARS_TEMPLATE:-}" ]]; then
  OVMF_VARS_TEMPLATE="${DEFAULT_OVMF_VARS[0]}"
fi

if [[ ! -r "$OVMF_VARS_TEMPLATE" ]]; then
  cat <<EOF >&2
[!] OVMF_VARS_TEMPLATE missing or unreadable at: $OVMF_VARS_TEMPLATE
    Checked candidates: ${DEFAULT_OVMF_VARS[*]}
    Install the 'ovmf' package (e.g. sudo apt install ovmf) or set OVMF_VARS_TEMPLATE to the matching vars image.
    On some systems the file is named OVMF_VARS_4M.fd.
EOF
  exit 1
fi

cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"
chmod u+rw,go-rwx "$OVMF_VARS"

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
sudo sed -i 's|---| console=ttyS0 earlyprintk=ttyS0  autoinstall  ds=nocloud\;d=/dev/sr1 autoinstall.debug ---|' "$GRUB_CFG"
# almost no grub timeout
sudo sed -i 's/^set timeout=.*/set timeout=1/' "$GRUB_CFG"
cat $GRUB_CFG > working/after_changes_grub.cfg


# change this other grub config to, note sure if its needed
GRUB_CFG="$WORKDIR/boot/grub/loopback.cfg"
cat $GRUB_CFG > working/before_changes_loopback.cfg
# here change the grub config
sudo sed -i 's|---| console=ttyS0 earlyprintk=ttyS0  autoinstall ds=nocloud\;d=/dev/sr1 autoinstall.debug  ---|' "$GRUB_CFG"
sudo sed -i 's/^set timeout=.*/set timeout=1/' "$GRUB_CFG"
cat $GRUB_CFG > working/after_changes_loopback.cfg


# now we build an iso that we will use
echo "[*] Rebuilding ISO: $OUT_ISO"
xorriso -indev "$ISO_PATH" \
  -outdev "$OUT_ISO" \
  -blank as_needed \
  -pathspecs on \
  -map "$WORKDIR/boot/grub/grub.cfg" "/boot/grub/grub.cfg" \
  -map "$WORKDIR/boot/grub/loopback.cfg" "/boot/grub/loopback.cfg" \
  -boot_image any replay


echo "[✓] Output ISO written to: $OUT_ISO"

# pkill -f qemu-system

echo "[*] Starting QEMU VM... , exit the QEMU with Ctrl-a  x"
qemu-system-x86_64 \
  -machine q35,accel=kvm \
  -m 5000 \
  -cpu host \
  -smp 12 \
  -enable-kvm \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -drive file="$OUT_ISO",media=cdrom,index=0 \
  -drive file="$NOCLOUD_ISO",media=cdrom,index=1 \
  -drive file="$DISK_IMG",format=qcow2,if=virtio \
  -boot order=d \
  -serial mon:stdio \
  -nographic \
  -no-reboot
#   -netdev user,id=net0 -device e1000,netdev=net0 \
# dont allow the vm to reboot so we catch it rebooting after install

end=$(date +%s)
echo ">>>> runtime $((end - start)) seconds"
