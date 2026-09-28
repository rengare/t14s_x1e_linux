#!/usr/bin/env bash

set -eu

# Reverse of install_t14s.sh: purges the kernel packages of one version and puts
# /boot back on another installed kernel (symlinks, EL1/EL2 device trees and the
# EL2 raw image), then regenerates the grub config.

usage() {
  cat <<'EOF'
Usage: uninstall_t14s.sh [OPTIONS]

Removes an installed kernel version and restores /boot for another one.

Options:
  -v, --version VER   Version to remove instead of the one in
                      debian.qcom-x1e/changelog
  -r, --restore REL   Kernel release to fall back to, e.g. 7.2-rc5-jg-0-qcom-x1e
                      (default: newest other kernel found in /boot)
  -n, --dry-run       Show what would be done, then exit
  -y, --yes           Do not prompt for confirmation
  -h, --help          Show this help
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

version=""
restore=""
dry_run=0
assume_yes=0

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--version) version="${2:?--version needs an argument}"; shift 2 ;;
    -r|--restore) restore="${2:?--restore needs an argument}"; shift 2 ;;
    -n|--dry-run) dry_run=1; shift ;;
    -y|--yes)     assume_yes=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "$version" ]; then
  version="$(dpkg-parsechangelog -l "$repo_root/debian.qcom-x1e/changelog" -S Version)"
fi

# Installed packages of that version, e.g. linux-image-7.3-rc3-jg-0-qcom-x1e.
# Matching on the "-VERSION" boundary keeps 7.3-rc3-jg-0 from catching 7.3-rc3-jg-01.
pkgs=()
while read -r name; do
  pkgs+=("$name")
done < <(dpkg-query -W -f='${Package}\n' 2>/dev/null \
           | grep -E "^linux-.*-${version//./\\.}(-|$)" || true)

if [ ${#pkgs[@]} -eq 0 ]; then
  echo "No installed packages found for version $version" >&2
  exit 1
fi

release=""
for pkg in "${pkgs[@]}"; do
  case "$pkg" in
    linux-image-*) release="${pkg#linux-image-}" ;;
  esac
done
[ -n "$release" ] || { echo "No linux-image package among the matches; cannot tell the release" >&2; exit 1; }

if [ "$(uname -r)" = "$release" ]; then
  echo "Refusing to remove $release: it is the running kernel." >&2
  echo "Boot another kernel first." >&2
  exit 1
fi

if [ -z "$restore" ]; then
  # Newest kernel that is not the one being removed. Versions like 7.2-rc5 do
  # not sort perfectly under sort -V, so the choice is printed for review.
  restore="$(ls -1 /boot/vmlinuz-* 2>/dev/null \
               | sed 's|.*/vmlinuz-||' \
               | grep -v -e '\.raw$' -e "^${release//./\\.}\$" \
               | sort -V | tail -n1)"
fi
[ -n "$restore" ] || { echo "No other kernel found in /boot; pass --restore" >&2; exit 1; }
[ -f "/boot/vmlinuz-$restore" ] || { echo "/boot/vmlinuz-$restore does not exist" >&2; exit 1; }
[ -f "/boot/initrd.img-$restore" ] || { echo "/boot/initrd.img-$restore does not exist" >&2; exit 1; }

dtb_dir="/usr/lib/firmware/$restore/device-tree/qcom"
for dtb in x1e78100-lenovo-thinkpad-t14s.dtb x1e78100-lenovo-thinkpad-t14s-el2.dtb; do
  [ -f "$dtb_dir/$dtb" ] || { echo "Missing $dtb_dir/$dtb" >&2; exit 1; }
done

echo "Remove:   $release"
for pkg in "${pkgs[@]}"; do
  printf '  %s\n' "$pkg"
done
echo "Restore:  $restore"
echo "  /boot/vmlinuz, /boot/initrd.img -> $restore"
echo "  /boot/dtb, /boot/dtb_el2        <- $dtb_dir"
echo "  /boot/vmlinuz.el2.raw           <- /boot/vmlinuz-$restore"

if [ "$dry_run" -eq 1 ]; then
  echo
  echo "Dry run; nothing changed."
  exit 0
fi

if [ "$assume_yes" -eq 0 ]; then
  echo
  read -r -p "Proceed? [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

sudo=""
[ "$(id -u)" -eq 0 ] || sudo="sudo"

$sudo apt-get purge -y "${pkgs[@]}"

# Package removal may leave these pointing at the removed kernel.
$sudo ln -sfn "vmlinuz-$restore" /boot/vmlinuz
$sudo ln -sfn "initrd.img-$restore" /boot/initrd.img
$sudo rm -f /boot/vmlinuz.old /boot/initrd.img.old

# install_t14s.sh overwrote these with the removed kernel's device trees.
$sudo install -m 0755 "$dtb_dir/x1e78100-lenovo-thinkpad-t14s.dtb" /boot/dtb
$sudo install -m 0644 "$dtb_dir/x1e78100-lenovo-thinkpad-t14s-el2.dtb" /boot/dtb_el2

# The raw image may be a symlink to the removed kernel's file; drop it first or
# objcopy/cp would write through the link. Also clean up the old
# vmlinuz-current-el2.raw / vmlinuz-$release.raw names from before the rename
# to vmlinuz.el2.raw (a "vmlinuz-*" name here fools 10_linux's kernel scan).
$sudo rm -f /boot/vmlinuz.el2.raw /boot/vmlinuz-current-el2.raw "/boot/vmlinuz-$release.raw"
if $sudo objdump -h "/boot/vmlinuz-$restore" | grep -qw '\.linux'; then
  $sudo objcopy -O binary --only-section=.linux "/boot/vmlinuz-$restore" /boot/vmlinuz.el2.raw
else
  $sudo cp "/boot/vmlinuz-$restore" /boot/vmlinuz.el2.raw
fi
$sudo chmod 0755 /boot/vmlinuz.el2.raw

$sudo update-grub

echo
echo "Removed $release; /boot now points at $restore."
