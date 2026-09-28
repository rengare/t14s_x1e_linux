#!/usr/bin/env bash

set -eu

# Installs the kernel .debs that rebuild_t14s.sh drops one level above the repo
# root. Package selection comes from the .changes manifest rather than a glob,
# so old builds sitting in the same directory are never picked up by accident.

usage() {
  cat <<'EOF'
Usage: install_t14s.sh [OPTIONS]

Installs the built kernel packages from the parent directory.

Options:
  -v, --version VER   Install this version instead of the one in
                      debian.qcom-x1e/changelog
  -m, --minimal       Install only linux-image and linux-modules (skips
                      headers, tools and buildinfo)
  -n, --dry-run       List what would be installed, then exit
  -y, --yes           Do not prompt for confirmation
  -s, --skip-boot-files
                      Only install the packages; do not refresh /boot/dtb,
                      /boot/dtb_el2 and /boot/vmlinuz.el2.raw
  -l, --list          List installed kernels in the parent directory and exit
  -h, --help          Show this help
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deb_dir="$(dirname "$repo_root")"

version=""
minimal=0
dry_run=0
assume_yes=0
skip_boot_files=0

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--version) version="${2:?--version needs an argument}"; shift 2 ;;
    -m|--minimal) minimal=1; shift ;;
    -n|--dry-run) dry_run=1; shift ;;
    -y|--yes)     assume_yes=1; shift ;;
    -s|--skip-boot-files) skip_boot_files=1; shift ;;
    -l|--list)
      echo "Kernel packages in $deb_dir:"
      ls -1 "$deb_dir"/*.deb 2>/dev/null | xargs -r -n1 basename || echo "  (none)"
      exit 0
      ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "$version" ]; then
  version="$(dpkg-parsechangelog -l "$repo_root/debian.qcom-x1e/changelog" -S Version)"
fi

arch="$(dpkg --print-architecture)"
changes="$deb_dir/linux-qcom-x1e_${version}_${arch}.changes"

debs=()
if [ -f "$changes" ]; then
  # The Files: stanza lists one file per line as: md5 size section priority name
  while read -r name; do
    debs+=("$deb_dir/$name")
  done < <(awk '/^Files:/{f=1;next} /^[^ ]/{f=0} f && $NF ~ /\.deb$/ {print $NF}' "$changes")
else
  echo "No manifest at $changes; falling back to matching .debs by version" >&2
  while read -r path; do
    debs+=("$path")
  done < <(ls -1 "$deb_dir"/*"${version}"*.deb 2>/dev/null)
fi

if [ ${#debs[@]} -eq 0 ]; then
  echo "No packages found for version $version in $deb_dir" >&2
  echo "Build them first with: $repo_root/rebuild_t14s.sh" >&2
  exit 1
fi

if [ "$minimal" -eq 1 ]; then
  filtered=()
  for deb in "${debs[@]}"; do
    case "$(basename "$deb")" in
      linux-image-*|linux-modules-*) filtered+=("$deb") ;;
    esac
  done
  debs=("${filtered[@]}")
fi

missing=0
for deb in "${debs[@]}"; do
  if [ ! -f "$deb" ]; then
    echo "Missing: $deb" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

echo "Version:  $version"
echo "From:     $deb_dir"
echo "Packages:"
for deb in "${debs[@]}"; do
  printf '  %s\n' "$(basename "$deb")"
done

if [ "$dry_run" -eq 1 ]; then
  echo
  echo "Dry run; nothing installed."
  exit 0
fi

if [ "$assume_yes" -eq 0 ]; then
  echo
  read -r -p "Install these packages? [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

sudo=""
[ "$(id -u)" -eq 0 ] || sudo="sudo"

# apt handles the dependency resolution that `dpkg -i` would leave half-done.
# The ./ prefix is what makes apt treat these as local files rather than names.
$sudo apt-get install -y "${debs[@]}"

if [ "$skip_boot_files" -eq 0 ]; then
  # Kernel release as the package names spell it, e.g. 7.3-rc3-jg-0-qcom-x1e.
  release=""
  for deb in "${debs[@]}"; do
    case "$(basename "$deb")" in
      linux-image-*)
        release="$(basename "$deb")"
        release="${release#linux-image-}"
        release="${release%%_*}"
        ;;
    esac
  done
  [ -n "$release" ] || { echo "No linux-image package in the list; cannot tell the release" >&2; exit 1; }

  dtb_dir="/usr/lib/firmware/$release/device-tree/qcom"
  vmlinuz="/boot/vmlinuz-$release"

  echo
  echo "Refreshing /boot files for $release"

  # /boot/dtb is the EL1 device tree, /boot/dtb_el2 the one for slbounce/EL2.
  $sudo install -m 0755 "$dtb_dir/x1e78100-lenovo-thinkpad-t14s.dtb" /boot/dtb
  $sudo install -m 0644 "$dtb_dir/x1e78100-lenovo-thinkpad-t14s-el2.dtb" /boot/dtb_el2

  # The EL2 loader wants the bare image. If the installed vmlinuz wraps it in a
  # .linux section (as the previous kernels here did), extract that section;
  # otherwise the package's vmlinuz already is the raw image.
  #
  # Named vmlinuz.el2.raw (a dot, not a dash, after "vmlinuz") on purpose: a
  # "vmlinuz-*" name here would make 10_linux and el2-grub-entry.sh mistake
  # this raw image for an installed kernel version.
  if $sudo objdump -h "$vmlinuz" | grep -qw '\.linux'; then
    $sudo objcopy -O binary --only-section=.linux "$vmlinuz" /boot/vmlinuz.el2.raw
  else
    $sudo cp "$vmlinuz" /boot/vmlinuz.el2.raw
  fi
  $sudo chmod 0755 /boot/vmlinuz.el2.raw

  # qebspil (loaded from the ESP before GRUB, see /boot/efi/startup.nsh) does
  # the real PAS cold-boot of the ADSP/CDSP under EL2, so Linux can attach to
  # fully-booted firmware instead of the bootloader's limited "lite" image.
  # It runs before the rootfs is mounted and can't decompress zstd, so it
  # needs plain copies of the board firmware staged on the ESP itself.
  fw_src_dir="/lib/firmware/qcom/x1e80100/LENOVO/21N1"
  fw_dst_dir="/boot/efi/firmware/qcom/x1e80100/LENOVO/21N1"
  $sudo mkdir -p "$fw_dst_dir"
  for f in qcadsp8380.mbn qccdsp8380.mbn adsp_dtbs.elf cdsp_dtbs.elf; do
    if [ -f "$fw_src_dir/$f.zst" ]; then
      $sudo zstd -d -f -o "$fw_dst_dir/$f" "$fw_src_dir/$f.zst"
    elif [ -f "$fw_src_dir/$f" ]; then
      $sudo cp "$fw_src_dir/$f" "$fw_dst_dir/$f"
    fi
  done
fi

echo
echo "Installed $version. The postinst hooks regenerate the initramfs and"
echo "bootloader entries; reboot to run it."
