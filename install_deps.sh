#!/usr/bin/env bash
set -euo pipefail

# Installs dependencies needed by ./autoinstall_vm.sh on Debian/Ubuntu.

REQUIRED_CMDS=(
  cloud-init
  yamllint
  cloud-localds
  wget
  qemu-img
  xorriso
  qemu-system-x86_64
  rsync
)

# Packages we always want even if the command check passes (e.g., firmware blobs)
EXTRA_APT_PACKAGES=(
  ovmf
)

# Map commands to apt packages (Debian/Ubuntu)
declare -A PKG_MAP=(
  [cloud-init]=cloud-init
  [yamllint]=yamllint
  [cloud-localds]=cloud-image-utils
  [wget]=wget
  [qemu-img]=qemu-utils
  [xorriso]=xorriso
  [qemu-system-x86_64]=qemu-system-x86
  [rsync]=rsync
)

need_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "[!] This script needs root privileges to install packages." >&2
    exit 1
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

ensure_on_apt_based() {
  if ! have apt-get; then
    echo "[!] apt-get not found. This installer targets Debian/Ubuntu." >&2
    echo "    Please install equivalents manually (e.g., on Fedora: dnf install cloud-utils-growpart cloud-utils qemu-img qemu-system-x86-core xorriso yamllint rsync wget)." >&2
    exit 1
  fi
}

main() {
  ensure_on_apt_based

  # Determine which packages are missing
  declare -A need_pkg=()
  for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! have "$cmd"; then
      pkg=${PKG_MAP[$cmd]:-}
      if [[ -z "$pkg" ]]; then
        echo "[!] No package mapping for command: $cmd" >&2
      else
        need_pkg[$pkg]=1
      fi
    fi
  done

  for pkg in "${EXTRA_APT_PACKAGES[@]}"; do
    need_pkg[$pkg]=1
  done

  if [[ ${#need_pkg[@]} -eq 0 ]]; then
    echo "[✓] All dependencies already installed."
    exit 0
  fi

  echo "[*] Will install packages: ${!need_pkg[*]}"

  # Elevate with sudo if not root
  if [[ $(id -u) -ne 0 ]]; then
    if have sudo; then
      # Re-exec as root via sudo
      exec sudo -E bash "$0"
    else
      echo "[!] sudo not found and not running as root." >&2
      exit 1
    fi
  fi

  # We are root here
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ${!need_pkg[*]}

  echo "[✓] Installation complete. Verifying..."
  missing=()
  for cmd in "${REQUIRED_CMDS[@]}"; do
    have "$cmd" || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "[!] Still missing: ${missing[*]}" >&2
    exit 2
  fi

  echo "[✓] All dependencies are available."
  echo "Tip: For KVM acceleration, ensure /dev/kvm exists and your user is in the 'kvm' group."
}

main "$@"
