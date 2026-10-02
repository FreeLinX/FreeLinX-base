#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# build-base.sh - build the FreeLinX base ISO: the system, a shell, no desktop.
#
#   sh build-base.sh            -> out/freelinx-base-x86_64.iso
#
# Base is the desktop release's system with the desktop taken out
# (scripts/mkrootfs.sh), so it has the same kernel, the same userland and the
# same no-GNU gate.  It boots the same way the desktop ISO does: the whole
# system is the initramfs, unpacked into ramfs, and /init runs runit.
#
# Installing is `flxinstall`, the installer the desktop ships.  It is the one
# that matches /init's boot model (system image on the ESP, persistent
# /usr /etc /var /root on FLX_SYS, /home on FLX_HOME, partitions pinned by
# UUID) and the one `flxupgrade` upgrades.  On an image with no desktop it
# installs a console system without asking.
#
# The medium is labelled FREELINX_LIVE because flxupgrade finds it by that.
#
# Environment:
#   DESK       the FreeLinX-desk checkout        (default: ../Desktop-test)
#   KERNEL     the kernel image                  (default: $DESK/kernel/bzImage)
#   LIMINE_DIR Limine binaries                   (default: $DESK/iso/limine)
#   OUT        the ISO to write    (default: out/freelinx-base-x86_64.iso)
#   SERIAL=1   also put the console on ttyS0 (for tests)
#   FLX_FIRMWARE_TARBALL  firmware-<kver>.tar.xz (default: $DESK/firmware-*.tar.xz)
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
DESK=${DESK:-$ROOT/Desktop-test}
KERNEL=${KERNEL:-$DESK/kernel/bzImage}
LIMINE_DIR=${LIMINE_DIR:-$DESK/iso/limine}
OUT=${OUT:-$HERE/out/freelinx-base-x86_64.iso}
VERSION=$(cat "$HERE/VERSION" 2>/dev/null || echo 1.0.7)

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '==> %s\n' "$*"; }

for t in xorriso cpio xz; do
	command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"
for f in limine limine-bios-cd.bin limine-uefi-cd.bin limine-bios.sys BOOTX64.EFI; do
	[ -f "$LIMINE_DIR/$f" ] || die "missing $LIMINE_DIR/$f"
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/flxbase.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
STAGE=$WORK/rootfs
ISO=$WORK/iso

# --- the system ----------------------------------------------------------------
DESK=$DESK sh "$HERE/scripts/mkrootfs.sh" -o "$STAGE"

mkdir -p "$STAGE/boot"
cp -f "$KERNEL" "$STAGE/boot/vmlinuz"

# Firmware is not in git (vendor blobs); without it real WiFi, GPUs and audio
# codecs do not come up.  The linux-firmware package already carries the
# common set; the tarball adds the rest when it is there.
FW=${FLX_FIRMWARE_TARBALL:-}
if [ -z "$FW" ]; then
	for c in "$DESK"/firmware-*.tar.xz; do [ -f "$c" ] && FW=$c && break; done
fi
if [ -n "$FW" ] && [ -f "$FW" ]; then
	step "firmware from ${FW##*/}"
	tar -xf "$FW" -C "$STAGE" lib/firmware
fi

# Modes git cannot carry, as the desktop image build sets them.
chmod 0600 "$STAGE/etc/shadow"
chmod 0700 "$STAGE/root"
chmod 1777 "$STAGE/tmp"
[ -d "$STAGE/var/tmp" ] && chmod 1777 "$STAGE/var/tmp"
for b in usr/bin/doas usr/sbin/unix_chkpwd bin/su bin/newgrp; do
	[ -f "$STAGE/$b" ] && chmod 4755 "$STAGE/$b"
done
if [ -f "$STAGE/usr/sbin/unix_chkpwd" ] && [ ! -e "$STAGE/sbin/unix_chkpwd" ]; then
	ln -s ../usr/sbin/unix_chkpwd "$STAGE/sbin/unix_chkpwd"
fi
[ -f "$STAGE/etc/doas.conf" ] && chmod 0600 "$STAGE/etc/doas.conf"
find "$STAGE" -name .gitkeep -type f -exec rm -f {} +
printf '%s\n' "$VERSION" >"$STAGE/etc/flx-base-version"

# The version base is released as.  /init compares VERSION_ID with the one
# recorded on FLX_SYS to decide whether an installed system's files need
# refreshing, flxinstall names the boot entries after it, and /init rewrites
# the " FreeLinX x.y.z" banner line in that exact form.
cat >"$STAGE/etc/os-release" <<EOF
NAME=FreeLinX
ID=freelinx
VERSION="$VERSION (base)"
VERSION_ID="$VERSION"
VERSION_CODENAME=base
PRETTY_NAME="FreeLinX $VERSION base"
ANSI_COLOR="1;36"
BUILD_ID="$VERSION"
HOME_URL="https://github.com/FreeLinX"
SUPPORT_URL="https://github.com/FreeLinX"
BUG_REPORT_URL="https://github.com/FreeLinX/FreeLinX-base/issues"
EOF
for f in etc/motd etc/issue; do
	[ -f "$STAGE/$f" ] || continue
	sed -i "s/^ FreeLinX 1\.0[0-9.]*\$/ FreeLinX $VERSION/" "$STAGE/$f"
	grep -q "^ FreeLinX $VERSION\$" "$STAGE/$f" || die "$f has no version line"
done

# The gate again, on what is actually packed (firmware included).
sh "$DESK/check-nognu.sh" "$STAGE" >"$WORK/nognu.txt" 2>&1 || {
	grep '^FAIL' "$WORK/nognu.txt" >&2
	die 'GNU artefacts in the image'
}
tail -1 "$WORK/nognu.txt"

# xz with CRC32 (what the kernel's decoder accepts).  Not zstd: Linux ignores a
# cpio appended after a zstd image, and flxinstall appends one.
step 'packing the initramfs'
mkdir -p "$ISO/boot/limine" "$ISO/EFI/BOOT"
(cd "$STAGE" && find . -print0 |
	cpio --null -o --quiet --format=newc --owner=0:0 |
	xz -T0 -6 --check=crc32) >"$ISO/boot/initramfs.img.gz"

# --- the medium ----------------------------------------------------------------
cp -f "$KERNEL" "$ISO/boot/bzImage"
cp -f "$LIMINE_DIR/limine-bios-cd.bin" "$LIMINE_DIR/limine-uefi-cd.bin" \
	"$LIMINE_DIR/limine-bios.sys" "$ISO/boot/limine/"
cp -f "$LIMINE_DIR/BOOTX64.EFI" "$ISO/EFI/BOOT/BOOTX64.EFI"

SERIAL_ARGS=; SERIAL_CONF=
if [ "${SERIAL:-0}" = 1 ]; then
	SERIAL_ARGS='console=ttyS0,115200'
	SERIAL_CONF='serial: yes'
fi
# rootfstype=ramfs: the unpacked system is bigger than tmpfs' default cap of
# half the RAM on a 2 GB machine.
cat >"$ISO/boot/limine/limine.conf" <<EOF
timeout: 5
$SERIAL_CONF
interface_branding: FreeLinX $VERSION base

/FreeLinX $VERSION base (installer: flxinstall)
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/initramfs.img.gz
    cmdline: rdinit=/init rootfstype=ramfs console=tty0 $SERIAL_ARGS quiet loglevel=2

/Rescue shell
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/initramfs.img.gz
    cmdline: rdinit=/init rootfstype=ramfs console=tty0 $SERIAL_ARGS flx.rescue=1
EOF

step "composing ${OUT##*/}"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
xorriso -as mkisofs -quiet -R -r -J -V FREELINX_LIVE \
	-b boot/limine/limine-bios-cd.bin -no-emul-boot -boot-load-size 4 \
	-boot-info-table -hfsplus -apm-block-size 2048 \
	--efi-boot boot/limine/limine-uefi-cd.bin -efi-boot-part --efi-boot-image \
	--protective-msdos-label "$ISO" -o "$OUT"
"$LIMINE_DIR/limine" bios-install "$OUT" >/dev/null 2>&1
(cd "$(dirname "$OUT")" && sha256sum "${OUT##*/}" >"${OUT##*/}.sha256")
step "done: $OUT ($(du -h "$OUT" | cut -f1))"
