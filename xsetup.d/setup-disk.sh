#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-disk - put FreeLinX on a disk, or run from RAM.
#
#   sys    install onto a disk.  Erases the disk chosen.
#   none   run from RAM, touching no disk.  Safe, and the default.
#
# What "installed" means is decided by /init, not here.  FreeLinX always runs
# from its initramfs; an installed system is one whose initramfs is on a disk
# and carries /etc/flx-installed, with its persistent trees on that disk:
#
#   ESP       FAT32, 1 GiB  kernel, the system image (this running system,
#                           with everything the earlier steps configured),
#                           Limine for UEFI and BIOS
#   BIOS boot 1 MiB         Limine's BIOS stage
#   FLX_SYS   ext4          /usr /etc /var /root /bin /sbin /lib, bound over
#                           the image by /init, so packages and settings stay
#   FLX_HOME  ext4          /home
#
# The two ext4 partitions are pinned by UUID in /etc/flx-disk, so another
# disk that happens to carry the same labels is never mounted.
#
# none is the default on purpose.  An installer that defaults to a disk is an
# installer that eats laptops, and the cost of being wrong is the machine.
# sys is never selected without saying what it will do and asking for the
# word "yes".  Nothing is written until that answer.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi
# A dry run writes nothing, so it does not need root; making it demand root
# would mean the plan could not be checked by the person considering it, on
# their own machine, before committing to it.  It is also what lets the test
# suite run without a loop device.
if [ "${XSETUP_DRY_RUN:-}" != 1 ]; then
	need_root
fi

# flxpart reports its layout as FLX_PART<n>_* on stdout, which is the only
# supported way to learn where the partitions ended up: reading the table back
# means re-implementing a GPT parser, and a second parser is a second thing to
# be wrong about what a partition is.
need_cmd flxpart 'the sysutils/flxpart port'

MODE_FILE=${XSETUP_STATE_FILE:-/etc/xsetup-disk-mode}
DONE_FILE=/etc/xsetup-disk-installed

# --dry-run: print every destructive step and do none of them.
#
# The whole of this step is irreversible, and the parts most likely to be
# wrong -- the partition naming, the fstab UUIDs, which device node is which
# partition -- are all decidable before anything is written.  So the plan can
# be shown and checked on a machine where the answer is not yet a formatted
# disk.  Read it as "this is what will happen", not as a promise that the
# commands would succeed.
DRY=0
case " ${XSETUP_DRY_RUN:-} " in
*" 1 "*) DRY=1 ;;
esac

# run CMD... - do a command, or say what it would have been.
run() {
	if [ "$DRY" -eq 1 ]; then
		printf '  would run: %s\n' "$*"
		return 0
	fi
	"$@"
}

# A scratch file for a tool's stderr, so a failure can be reported with what the
# tool said rather than only that it failed.  Not in /tmp: this runs from a
# read-only medium as often as from a live system, and /tmp may be either.
#
# The directory is created first, because mktemp does not create its parent and
# says so by failing.  /var/tmp is in most of the FHS but it is not something an
# initramfs has, and this step is run from one: booting base.iso produced
#
#   mktemp: mkstemp failed on /var/tmp/xsetup.XXXXXX: No such file or directory
#
# and then carried on with TMPERR naming a file that did not exist, so every
# later "here is what the tool said" report was empty.  A failure to make the
# directory at all is fatal, because it means nowhere writable to be found.
_scratchdir=${TMPDIR:-/var/tmp}
[ -d "$_scratchdir" ] || mkdir -p "$_scratchdir" ||
	die "cannot create $_scratchdir to use for scratch files, and there is no writable directory to fall back to"
TMPERR=${TMPERR:-$(mktemp "$_scratchdir/xsetup.XXXXXX")}

# The layout flxpart would produce, so a dry run can show the geometry without
# writing a table.  On a real run this comes from the real partitioning.
_layout=

# --- the choice ------------------------------------------------------------

mode=$(choose 'How should the system be stored?' \
	none 'run from RAM, no disk is written' \
	sys 'install onto a disk (erases it)')

printf '%s\n' "$mode" >"$MODE_FILE"

if [ "$mode" = none ]; then
	rm -f "$DONE_FILE"
	ok 'running from RAM. No disk is written.'
	say ''
	say 'Nothing is kept after a reboot.  Run xsetup setup-disk again and'
	say 'choose sys to install the system onto a disk.'
	return 0
fi

# --- refusing early -------------------------------------------------------

# A disk that is not there cannot be chosen, and neither can a mounted one.
# Writing to a mounted filesystem destroys the mount, not just the data.
disks() {
	# XSETUP_DISK_OVERRIDE exists so the test suite can run this step
	# without root and without a loop device, by naming a plain file in
	# place of a disk.  It only makes sense with --dry-run: a real run
	# against a regular file would format a file and call it a disk.
	if [ -n "${XSETUP_DISK_OVERRIDE:-}" ]; then
		[ "$DRY" -eq 1 ] ||
			die 'XSETUP_DISK_OVERRIDE is only honoured with --dry-run'
		[ -e "$XSETUP_DISK_OVERRIDE" ] ||
			die "XSETUP_DISK_OVERRIDE: $XSETUP_DISK_OVERRIDE does not exist"
		printf '%s\n' "$XSETUP_DISK_OVERRIDE"
		return 0
	fi
	_d=
	for p in /dev/sd? /dev/nvme?n? /dev/vd? /dev/xvd? /dev/mmcblk?; do
		[ -b "$p" ] || continue
		# Skip the device a CD-ROM is attached as, and every partition:
		# partitioning /dev/sda1 is not a thing anyone means.
		case $p in
		*[0-9][0-9]) continue ;;
		esac
		_d=$_d${_d:+ }$p
	done
	printf '%s\n' "$_d"
	unset _d
}

devs=$(disks)
if [ -z "$devs" ]; then
	die 'no disk was found. Nothing was changed.'
fi

info 'disks found:'
for d in $devs; do
	# the size of the disk itself (df would measure the filesystem /dev is on)
	if [ -r "/sys/class/block/${d##*/}/size" ]; then
		_dsize="$(( $(cat "/sys/class/block/${d##*/}/size") / 2097152 )) GiB"
	else
		_dsize="$(( $(wc -c <"$d" | tr -d ' ') / 1073741824 )) GiB"
	fi
	_model=$(cat "/sys/class/block/${d##*/}/device/model" 2>/dev/null | tr -s ' ')
	printf '  %-16s %s%s\n' "$d" "$_dsize" "${_model:+  $_model}"
done
printf '\n'

# shellcheck disable=SC2086
dev=$(choose 'Which disk' none 'leave it alone' \
	$(for d in $devs; do printf '%s %s ' "$d" "$d"; done))
[ "$dev" = none ] && die 'no disk was chosen, so nothing was written'

# Anything mounted out of this device stops the install.  Silently
# partitioning a live system is how an upgrade destroys itself.
if command -v findmnt >/dev/null 2>&1; then
	mounted=$(findmnt -rno SOURCE 2>/dev/null | grep -c "^$dev[0-9p]*$" || true)
	if [ "${mounted:-0}" -gt 0 ]; then
		die "$dev has ${mounted} filesystem(s) mounted. Unmount them, or pick another disk.
     Nothing was changed."
	fi
elif mount 2>/dev/null | grep -q "^$dev"; then
	die "$dev is mounted. Unmount it, or pick another disk. Nothing was changed."
fi

printf '\n'
warn "about to erase $dev, and everything on it"
warn "$mode mode reformats it: the previous contents are not recoverable."
confirm "This erases $dev" || die 'nothing was changed'

# --- layout vocabulary ------------------------------------------------------

# Type GUIDs as flxpart prints them: the on-disk (mixed-endian) byte order.
GUID_ESP=28732AC1-1FF8-D211-BA4B-00A0C93EC93B
GUID_BIOSBOOT=48616821-4964-6F6E-744E-656564454649
GUID_LINUX=AF3DC60F-8384-7247-8E79-3D69D8477DE4

# part_indices GUID - the numbers of the partitions of that type, in order.
part_indices() {
	printf '%s\n' "$layout" | sed -n "s/^FLX_PART\([0-9]*\)_TYPE=$1\$/\1/p"
}

# partdev DEVICE INDEX - /dev/sda + 1 -> /dev/sda1; nvme, mmc and loop put a
# "p" in front of the number.
partdev() {
	case $1 in
	*/nvme?n*|*/mmcblk*|*/loop*) printf '%sp%s\n' "$1" "$2" ;;
	*) printf '%s%s\n' "$1" "$2" ;;
	esac
}

# --- sizes --------------------------------------------------------------------

# The system partition holds everything xpkg installs, so it gets a share of
# the disk rather than a fixed size: 30% (at least 6 GiB, at most 64 GiB) on
# disks of 20 GiB and more, 40% (at least 3 GiB) on smaller ones.  /home gets
# the rest.  The same rule as the desktop installer.
if [ -r "/sys/class/block/${dev##*/}/size" ]; then
	disk_mb=$(( $(cat "/sys/class/block/${dev##*/}/size") / 2048 ))
else
	disk_mb=$(( $(wc -c <"$dev" | tr -d ' ') / 1048576 ))
fi
[ "$disk_mb" -ge 8192 ] ||
	die "$dev is $disk_mb MiB; an install needs at least 8 GiB.  Nothing was written."
if [ "$disk_mb" -ge 20480 ]; then
	sys_mb=$(( disk_mb * 30 / 100 ))
	[ "$sys_mb" -lt 6144 ] && sys_mb=6144
	[ "$sys_mb" -gt 65536 ] && sys_mb=65536
else
	sys_mb=$(( disk_mb * 40 / 100 ))
	[ "$sys_mb" -lt 3072 ] && sys_mb=3072
fi
esp_mb=1024

# --- partitioning -----------------------------------------------------------

need_cmd mkfs.fat 'the sysutils/dosfstools port'
need_cmd mkfs.ext4 'the sysutils/e2fsprogs port'

if [ "$DRY" -eq 1 ]; then
	layout=$(flxpart --esp-size "$esp_mb" --flx-sys-size "$sys_mb" \
		--create-standard --dry-run "$dev") ||
		die "flxpart could not compute a layout for $dev"
else
	# flxautomount mounts new partitions as they appear; this flag (shared
	# with the desktop installer, hence the name) makes it step aside.
	: >/run/flxinstall-active
	for p in "$dev"?* ; do
		[ -b "$p" ] && umount "$p" 2>/dev/null
	done
	info "partitioning $dev"
	layout=$(flxpart --esp-size "$esp_mb" --flx-sys-size "$sys_mb" \
		--create-standard "$dev") ||
		die "flxpart could not partition $dev"
fi

esp_i=$(part_indices "$GUID_ESP" | head -1)
bios_i=$(part_indices "$GUID_BIOSBOOT" | head -1)
sys_i=$(part_indices "$GUID_LINUX" | sed -n 1p)
home_i=$(part_indices "$GUID_LINUX" | sed -n 2p)
[ -n "$esp_i" ] && [ -n "$bios_i" ] && [ -n "$sys_i" ] && [ -n "$home_i" ] ||
	die "flxpart did not report the four partitions.  It said:
$layout"

ESP_DEV=$(partdev "$dev" "$esp_i")
SYS_DEV=$(partdev "$dev" "$sys_i")
HOME_DEV=$(partdev "$dev" "$home_i")
size_of() {
	printf '%s\n' "$layout" | sed -n "s/^FLX_PART$1_SIZE_MB=//p"
}
say ''
say "  EFI system  $ESP_DEV   $(size_of "$esp_i") MiB  kernel, system image, Limine"
say "  BIOS boot   $(partdev "$dev" "$bios_i")   1 MiB  Limine's BIOS stage"
say "  system      $SYS_DEV   $(size_of "$sys_i") MiB  /usr /etc /var /root /bin /sbin /lib"
say "  home        $HOME_DEV   $(size_of "$home_i") MiB  /home"
say ''

if [ "$DRY" -eq 1 ]; then
	say "  would run: mkfs.fat -F 32 -n FLX_BOOT $ESP_DEV"
	say "  would run: mkfs.ext4 -F -q -L FLX_SYS $SYS_DEV"
	say "  would run: mkfs.ext4 -F -q -L FLX_HOME $HOME_DEV"
	say '  would write: the kernel and this system, as configured, to the ESP'
	say '  would seed: FLX_SYS from this system, /home onto FLX_HOME'
	say '  would install: Limine for UEFI and BIOS'
	say ''
	say "  (dry run: nothing has been written to $dev)"
	return 0
fi

# The kernel makes the partition nodes, mdevd puts them in /dev: wait for them.
n=0
while [ ! -b "$ESP_DEV" ] || [ ! -b "$HOME_DEV" ]; do
	n=$((n + 1))
	[ "$n" -le 20 ] || die "the partitions of $dev did not appear in /dev"
	sleep 0.5
done

cleanup() {
	for m in /mnt/flx_home /mnt/flx_sys /mnt/flx_boot; do
		umount "$m" 2>/dev/null || :
	done
	rm -f /run/flxinstall-active "$TMPERR" 2>/dev/null || :
}
trap cleanup EXIT INT TERM

info 'formatting'
mkfs.fat -F 32 -n FLX_BOOT "$ESP_DEV" >/dev/null 2>"$TMPERR" ||
	die "mkfs.fat failed on $ESP_DEV: $(head -2 "$TMPERR")"
mkfs.ext4 -F -q -L FLX_SYS "$SYS_DEV" 2>"$TMPERR" ||
	die "mkfs.ext4 failed on $SYS_DEV: $(head -2 "$TMPERR")"
mkfs.ext4 -F -q -L FLX_HOME "$HOME_DEV" 2>"$TMPERR" ||
	die "mkfs.ext4 failed on $HOME_DEV: $(head -2 "$TMPERR")"
ok 'ESP, FLX_SYS and FLX_HOME formatted'

part_uuid() {
	blkid "$1" 2>/dev/null | grep -o ' UUID="[^"]*"' | cut -d'"' -f2
}
SYS_UUID=$(part_uuid "$SYS_DEV")
HOME_UUID=$(part_uuid "$HOME_DEV")
[ -n "$SYS_UUID" ] && [ -n "$HOME_UUID" ] ||
	die 'could not read the new filesystems'"'"' UUIDs'

# The live user (autologin on the live medium, doas without a password) must
# not reach the installed system.  strip_live ROOT edits ROOT/etc in place.
strip_live() {
	_e=$1/etc
	for _f in passwd shadow; do
		[ -f "$_e/$_f" ] || continue
		grep -v '^live:' "$_e/$_f" >"$_e/$_f.new"
		cat "$_e/$_f.new" >"$_e/$_f"
		rm -f "$_e/$_f.new"
	done
	if [ -f "$_e/group" ]; then
		awk -F: 'BEGIN { OFS = ":" } $1 == "live" { next }
		{ n = split($4, m, ","); o = ""
		  for (i = 1; i <= n; i++) if (m[i] != "live" && m[i] != "") o = o (o == "" ? "" : ",") m[i]
		  $4 = o; print }' "$_e/group" >"$_e/group.new"
		cat "$_e/group.new" >"$_e/group"
		rm -f "$_e/group.new"
	fi
	if [ -f "$_e/doas.conf" ]; then
		grep -v 'permit nopass keepenv live$' "$_e/doas.conf" |
			grep -v '^# live ISO session user' >"$_e/doas.conf.new"
		cat "$_e/doas.conf.new" >"$_e/doas.conf"
		rm -f "$_e/doas.conf.new"
	fi
}

# --- the ESP: kernel, system image, bootloader -------------------------------

mkdir -p /mnt/flx_boot
mount -t vfat "$ESP_DEV" /mnt/flx_boot || die "cannot mount $ESP_DEV"
mkdir -p /mnt/flx_boot/boot /mnt/flx_boot/EFI/BOOT

KERNEL_SRC=
for k in /boot/vmlinuz /boot/bzImage; do
	[ -f "$k" ] && KERNEL_SRC=$k && break
done
[ -n "$KERNEL_SRC" ] || die 'there is no kernel in /boot to install'
cp "$KERNEL_SRC" /mnt/flx_boot/boot/bzImage || die 'could not copy the kernel'
ok 'kernel installed'

# The system image is this running system, with what the earlier steps wrote
# into /etc, marked installed.  /home is not in it: it lives on FLX_HOME.
need_cmd cpio 'cpio'
need_cmd xz 'xz'
: >/etc/flx-installed
info 'writing the system image (a few minutes)'
( cd / && find . -xdev \
	-not -path './proc/*' -not -path './sys/*' -not -path './dev/*' \
	-not -path './run/*' -not -path './tmp/*' -not -path './mnt/*' \
	-not -path './media/*' -not -path './home/*' -print0 |
	cpio --null -o --format=newc 2>/dev/null |
	xz -3 -T0 --check=crc32 ) >/mnt/flx_boot/boot/initramfs.img.gz ||
	die 'could not write the system image to the ESP'

# Appended to the image (the kernel unpacks every archive in turn, the last
# copy of a file wins): /etc without the live user, and the UUID pins.
ov=$(mktemp -d "${_scratchdir:-/var/tmp}/xsetup-ov.XXXXXX")
mkdir -p "$ov/etc"
for f in passwd shadow group doas.conf; do
	[ -f "/etc/$f" ] && cp -p "/etc/$f" "$ov/etc/"
done
strip_live "$ov"
printf 'FLX_SYS_UUID=%s\nFLX_HOME_UUID=%s\n' "$SYS_UUID" "$HOME_UUID" >"$ov/etc/flx-disk"
( cd "$ov" && find ./etc -print0 | cpio --null -o --format=newc 2>/dev/null ) \
	>>/mnt/flx_boot/boot/initramfs.img.gz || die 'could not finish the system image'
ok "system image written ($(du -h /mnt/flx_boot/boot/initramfs.img.gz | cut -f1))"

# Kernel modules of a kernel later updated with xpkg go here; empty for now.
( cd "$ov" && printf '' | cpio -o --format=newc 2>/dev/null ) >/mnt/flx_boot/boot/kmods.cpio

LIMDIR=${LIMINE_DIR:-/usr/share/limine}
for f in BOOTX64.EFI limine-bios.sys; do
	[ -f "$LIMDIR/$f" ] || die "$LIMDIR/$f is missing, so there is no bootloader to install"
done
cp "$LIMDIR/BOOTX64.EFI" /mnt/flx_boot/EFI/BOOT/BOOTX64.EFI
cp "$LIMDIR/limine-bios.sys" /mnt/flx_boot/boot/limine-bios.sys
cp "$LIMDIR/limine-bios.sys" /mnt/flx_boot/limine-bios.sys
ver=$(sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release 2>/dev/null)
ver=${ver:-1.0}
cat >/mnt/flx_boot/limine.conf <<EOF
# Written by xsetup.
timeout: 3
serial: yes
interface_branding: FreeLinX $ver

/FreeLinX $ver
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/initramfs.img.gz
    module_path: boot():/boot/kmods.cpio
    cmdline: rdinit=/init rootfstype=ramfs console=tty0 console=ttyS0,115200 quiet loglevel=2

/Rescue shell
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/initramfs.img.gz
    module_path: boot():/boot/kmods.cpio
    cmdline: rdinit=/init rootfstype=ramfs flx.rescue=1 console=tty0 console=ttyS0,115200
EOF
cp /mnt/flx_boot/limine.conf /mnt/flx_boot/boot/limine.conf
cp /mnt/flx_boot/limine.conf /mnt/flx_boot/EFI/BOOT/limine.conf
need_cmd limine 'limine'
limine bios-install "$dev" "$bios_i" >"$TMPERR" 2>&1 ||
	warn "limine bios-install failed, so the disk boots on UEFI only: $(tail -1 "$TMPERR")"
ok 'Limine installed for UEFI and BIOS'

# --- FLX_SYS: the persistent system trees -----------------------------------

mkdir -p /mnt/flx_sys
mount -t ext4 "$SYS_DEV" /mnt/flx_sys || die "cannot mount $SYS_DEV"
info 'seeding the system partition'
for d in usr etc var root bin sbin lib; do
	( cd / && tar -cf - "$d" ) | ( cd /mnt/flx_sys && tar -xpf - ) ||
		die "could not copy /$d to the system partition"
done
strip_live /mnt/flx_sys
cp "$ov/etc/flx-disk" /mnt/flx_sys/etc/flx-disk
printf '%s\n' "$ver" >/mnt/flx_sys/.flx-image-version
rm -rf "$ov"
ok 'system partition seeded'

# --- FLX_HOME: the users' homes -----------------------------------------------

mkdir -p /mnt/flx_home
mount -t ext4 "$HOME_DEV" /mnt/flx_home || die "cannot mount $HOME_DEV"
awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "live" && $6 ~ /^\/home\// { print $1, $3, $4, $6 }' \
	/etc/passwd | while read -r u uid gid h; do
	if [ -d "$h" ]; then
		( cd /home && tar -cf - "${h#/home/}" ) | ( cd /mnt/flx_home && tar -xpf - )
	fi
	mkdir -p "/mnt/flx_home/${h#/home/}"
	chown -R "$uid:$gid" "/mnt/flx_home/${h#/home/}"
	chmod 700 "/mnt/flx_home/${h#/home/}"
	ok "home for $u on FLX_HOME"
done

sync
cleanup
# give the dispatcher back its own trap (this step is sourced by it)
if [ -n "${WORK:-}" ]; then
	trap 'rm -rf "$WORK"' EXIT INT TERM
else
	trap - EXIT INT TERM
fi
: >"$DONE_FILE"
ok "FreeLinX is installed on $dev"
say ''
say 'Steps 12 and 13 have nothing to do on an installed system.  When xsetup'
say 'is done, reboot, remove the medium, and boot from the disk.'
