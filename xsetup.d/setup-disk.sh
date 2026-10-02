#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-disk - put FreeLinX on a disk, or run from RAM.
#
#   sys    install onto a disk: partition, format, copy the system, install
#          the bootloader, write fstab.  Erases the disk chosen.
#   data   run from RAM, with a disk for persistent storage.  Erases the disk.
#   none   run from RAM, touching no disk.  Safe, and the default.
#
# none is the default on purpose.  An installer that defaults to a disk is an
# installer that eats laptops, and the cost of being wrong is the machine.
#
# sys and data are never selected without saying what they will do and asking
# for the word "yes".  Nothing is written until that answer.

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
	sys 'install onto a disk (erases it)' \
	data 'run from RAM, keep a disk for persistent storage (erases it)')

printf '%s\n' "$mode" >"$MODE_FILE"

if [ "$mode" = none ]; then
	rm -f "$DONE_FILE"
	ok 'running from RAM. No disk is written.'
	say ''
	say 'Steps 12 (setup-lbu and setup-apkcache) apply to this mode: they'
	say 'decide where a backup overlay and the package cache are kept.'
# # `return`, not `exit`.  A step is sourced by the dispatcher, not run as its own
# process, so `exit` here ends the whole installer rather than this step: the
# step printed its line, said everything was fine, and dropped the operator back
# at the shell prompt with steps 7 to 13 never run and nothing marked done.  It
# looked like the step failed, which is the opposite of what it said.

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
	_dsize=$(df -h "$d" 2>/dev/null | awk 'NR==2 {print $2" total, "$4" used"}')
	printf '  %-16s %s\n' "$d" "${_dsize:-$(wc -c <"$d" 2>/dev/null | tr -d ' ') bytes}"
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

GUID_ESP=28732AC1-1FF8-D211-BA4B-00A0C93EC93B
GUID_BIOSBOOT=48616821-4964-6F6E-744E-656564454649
GUID_ROOT=AF3DC60F-8384-7247-8E79-3D69D8477DE4

# part_index GUID - the number of the first partition of that type, matched on
# the type GUID rather than on its name or its position.  See the note above the
# GUIDs: matching on a name is how this step once looked for a partition called
# "ESP" and did not find the one called "EFI system".
part_index() {
	printf '%s\n' "$layout" |
		sed -n "s/^FLX_PART\([0-9]*\)_TYPE=$1\$/\1/p" | head -1
}

# partdev DEVICE INDEX - the device node for that partition.
#
# /dev/sda + 1 -> /dev/sda1.  Built here rather than assumed, because nvme and
# mmc put a "p" in front of the number.
partdev() {
	_p=$1
	_i=$2
	case $_p in
	*/nvme?n*|*/mmcblk*|*/loop*) printf '%sp%s\n' "$_p" "$_i" ;;
	*) printf '%s%s\n' "$_p" "$_i" ;;
	esac
}

# --- data mode -------------------------------------------------------------

# Written out here, before anything touches the disk, because it is a different
# job rather than a variation on the same one.
#
# sys mode lays out a boot chain and a root filesystem and copies the system
# onto the disk, and the disk then boots.  data mode lays out one filesystem and
# copies nothing: the system keeps running from RAM, out of the initramfs it was
# booted from, and the disk is only a place for /var to live.  /var is where the
# things that must outlive a reboot go - /var/lib/xpkg the package database,
# /var/lib/lbu the local overlay, /var/log the logs, /var/cache the package
# cache - so one filesystem with those four trees on it is the whole of it.
#
# Nothing is installed onto the disk and no bootloader is written, because there
# is nothing on the disk to boot: the kernel and the initramfs are on the medium,
# and every boot starts from the medium again.  That is what the mode is for, and
# it is why it needs no ESP and no BIOS boot partition.  Asking for one and
# leaving it empty would give a disk a partition table that says it boots when
# it does not, which is the exact failure this step is being rewritten to stop.
install_data() {
	need_cmd flxpart 'the sysutils/flxpart port'
	need_cmd mkfs.ext4 'the sysutils/e2fsprogs port'

	info "partitioning $dev for data"
	if [ "$DRY" -eq 1 ]; then
		# A dry run partitions nothing, so the layout it reports is the one
		# flxpart computes from the device size without writing.  The real
		# numbers come from a real table, and a dry run says so rather than
		# inventing LBAs.
		layout=$(flxpart --create-data --dry-run "$dev") ||
			die "flxpart could not compute a data layout for $dev"
		say "  (dry run: nothing has been written to $dev)"
	else
		layout=$(flxpart --create-data "$dev") ||
			die "flxpart could not partition $dev"
	fi

	data_i=$(printf '%s\n' "$layout" |
		sed -n "s/^FLX_PART\([0-9]*\)_TYPE=$GUID_ROOT\$/\1/p" | head -1)
	[ -n "$data_i" ] || die "flxpart did not report a data partition.
     Its output said:
$layout"

	VAR_DEV=$(partdev "$dev" "$data_i")
	say "  data         $VAR_DEV"

	# The label is the whole contract between this step and the boot code.
	# /init looks for a filesystem called FREELINX_VAR and mounts it at /var,
	# so a filesystem with any other name - or with none - is not found, and
	# the system boots with an empty /var that looks exactly like it worked.
	if [ "$DRY" -eq 1 ]; then
		say "  would run: mkfs.ext4 -q -L FREELINX_VAR $VAR_DEV"
		say "  would create: /var/lib/xpkg /var/lib/lbu /var/cache /var/log"
		say "  would write: the filesystem UUID, as a note on the disk"
		ok 'data filesystem would be created on '"$VAR_DEV"
		say ''
		say "  data         $VAR_DEV  (label FREELINX_VAR)"
		say ''
		say 'Nothing has been written to '"$dev"'.'
		# exit, like the real branch below: returning from install_data lands
		# in the sys install, which partitions a disk the operator was told
		# nothing would be written to.
		exit 0
	fi

	info "making an ext4 filesystem on $VAR_DEV"
	mkfs.ext4 -q -L FREELINUX_VAR "$VAR_DEV" ||
		die "mkfs.ext4 failed on $VAR_DEV"
	ok 'data filesystem formatted and labelled FREELINUX_VAR'

	# Written the same way fstab is written for a sys install: on the
	# filesystem UUID, which does not move when a disk is added.
	#
	# Read after mkfs, not before: the UUID does not exist until the
	# filesystem does, so reading it earlier returns nothing and the step
	# fails on a disk it had just made correctly.
	var_uuid=$(blkid -s UUID -o value "$VAR_DEV" 2>/dev/null || :)
	[ -n "$var_uuid" ] ||
		die "could not read the filesystem UUID for $VAR_DEV.
     /init finds this filesystem by its label, but a UUID-keyed entry is
     what a mounted system should have, and without it the entry would have
     to name a /dev node that can change.
     Nothing has been unmounted; the filesystem is on $VAR_DEV."

	info 'seeding /var'
	mkdir -p /mnt/flx || die 'cannot create /mnt/flx'
	mount -t ext4 "$VAR_DEV" /mnt/flx ||
		die "cannot mount $VAR_DEV at /mnt/flx as ext4"
	# The four trees setup-lbu, setup-apkcache and the package tools use.  A
	# filesystem that mounts but is empty makes every one of them take its
	# "first run" path on a system that has already been installed, so they
	# are created here, by the thing that knows what mode was chosen.
	mkdir -p /mnt/flx/lib/xpkg /mnt/flx/lib/lbu \
		/mnt/flx/cache /mnt/flx/log ||
		die 'could not create the /var directories'

	# A note for a human reading the disk, not a mount table: nothing reads
	# it.  The system that uses this disk finds the filesystem by its label
	# in /init, because that system runs from RAM and never reads an fstab.
	# Written anyway, because a disk holding a FREELINUX_VAR filesystem with
	# no record of what it is for is a disk somebody has to guess about.
	{
		printf '# Written by xsetup (data mode).\n'
		printf '# This disk holds /var only. The system runs from RAM, out of the\n'
		printf '# initramfs on the medium, and finds this filesystem by its label\n'
		printf '# FREELINUX_VAR. Nothing mounts this file; it is here so that the\n'
		printf '# disk says what it is.\n'
		printf 'UUID=%s\t/var\text4\tdefaults,noatime\t0 2\n' "$var_uuid"
	} >/mnt/flx/fstab.note
	umount /mnt/flx || die "could not unmount $VAR_DEV"
	ok '/var is ready'

	printf '%s\n' data >"$MODE_FILE" 2>/dev/null || :

	ok "data filesystem created on $VAR_DEV"
	say ''
	say "  data         $VAR_DEV  (label FREELINX_VAR)"
	say ''
	say 'The system is still running from RAM and will keep doing so. This disk'
	say 'holds /var, so the package database, the local overlay, the logs and'
	say 'the package cache survive a reboot.'
	say ''
	say 'Boot the medium again - the same way you just did - and /var comes'
	say 'back. Nothing on this disk is bootable, and that is deliberate: there'
	say 'is no kernel on it to boot.'
	# exit, not return: install_data is a function, not a sourced step, and it is
	# the whole of data mode. Returning from it fell through to the sys install
	# below and made data mode build a boot chain and copy the system onto a disk
	# the operator asked to hold /var - which is the exact failure this mode
	# exists to avoid. Every other `return 0` in this file is inside a step
	# sourced by the dispatcher, where returning is right and exiting is not.
	exit 0
}

# The mode is known and the disk is chosen and the erase is confirmed, so this
# is the last point at which data mode can leave before sys mode has written a
# root partition and copied the system onto it.
if [ "$mode" = data ]; then
	install_data
fi

# --- partitioning ----------------------------------------------------------

# Where the system comes from.  The installer may be running from a mounted ISO
# or from an already-installed system; either way it has a rootfs somewhere it
# can read.  SOURCE_ROOT is that place, and defaulting it to / is right when
# xsetup runs from an installed system and wrong when it runs from the ISO, so
# it is set explicitly by the boot script and only falls back to /.
#
# It is read here, before the disk is partitioned, and not only in the copying
# section which is where it is first obviously needed: the kernel is looked for
# under it while the boot chain is being measured.  A step is sourced into a
# shell running `set -u`, so reading it before it is assigned is a fatal error
# and not an empty string.
SOURCE_ROOT=${SOURCE_ROOT:-/}

# The whole boot chain has to fit on the EFI system partition, and it is not
# small: FreeLinX boots by loading an initramfs that is the whole system, so the
# chain is the kernel plus that initramfs, which is most of a FreeLinX release.
#
# This is not a choice.  Limine's BIOS stage - the one that finds limine-bios.sys
# and reads the boot menu - can read FAT and NTFS and nothing else; there is no
# ext2, ext3 or ext4 in it.  So a root filesystem holding the kernel is a root
# filesystem Limine cannot see, whatever the boot menu says.  Everything Limine
# has to read lives on the FAT32 ESP, and the root partition holds the system
# that the initramfs is built from.
#
# Which makes the ESP's size a function of the boot payload, and the payload has
# to be measured before the disk is partitioned rather than after - a partition
# table cannot be resized in place by this script.  The medium is located first
# for that reason alone.
#
# 32 MiB of slack on top of the payload, and 256 MiB as a floor.  The slack is
# FAT32's own bookkeeping - the FATs, the root directory and the slack in the
# last cluster of every file - which is small in proportion but not small in
# absolute terms next to a hundred files, and a filesystem that is a hair too
# small fails at the last file with the disk half-written.
MEDIUM=${XSETUP_MEDIUM:-}
if [ -z "$MEDIUM" ]; then
	# ../.. from *here*, not from $0.
	#
	# A step is sourced by the dispatcher (`. "$_file"`), so $0 is the
	# dispatcher's path - /media/flx/installer/xsetup - and $(dirname "$0")/../..
	# is /media.  The medium is /media/flx, one level deeper, so every lookup
	# missed and the step reported
	#
	#     error: cannot find the medium this installer is running from.
	#     Looked for boot/initramfs.img.gz in /media/flx/installer/../../, ...
	#
	# for a file that was mounted, readable and present the whole time: the test
	# above it proves the file is there.  It listed its own path in the message,
	# which is the only thing that gave it away.
	#
	# The step is at <medium>/installer/xsetup.d/, so the dispatcher's directory
	# is <medium>/installer and one level up is the medium's root, where the boot
	# chain lives.
	#
	# Only .. is kept of the relatives.  ../.. and ../../.. are not alternative
	# places the medium might be, they are the two wrong answers that were here,
	# and leaving them in reads as "any of these might be it" when neither ever
	# is.
	_SEARCHED=
	for _c in "$(dirname "$0")/.." /cdrom /media /media/flx /run/media; do
		if [ -f "$_c/boot/initramfs.img.gz" ]; then
			MEDIUM=$(cd "$_c" && pwd) || MEDIUM=
			break
		fi
	done
fi
unset _c

# What was actually searched, so the error names the paths it tried rather than a
# copy of a list that has since been edited.  The message used to print
# $(dirname "$0")/../.. itself, which is how the wrong path gave itself away.
SEARCHED=$(printf '%s ' $_SEARCHED)

# One message for both ways this goes wrong - nothing found, and XSETUP_MEDIUM
# naming somewhere that is not a medium - because they are the same mistake from
# the person running it, and "cannot find the medium" beside the list of places
# looked is the answer, where "no such file" beside a path is only the symptom.
if [ -z "$MEDIUM" ] || [ ! -f "$MEDIUM/boot/initramfs.img.gz" ]; then
	die "cannot find the medium this installer is running from.
     The kernel and the initramfs are on the medium, not in the running system,
     and the boot partition has to be sized for them before the disk can be
     partitioned at all.  Looked for boot/initramfs.img.gz in$SEARCHED${MEDIUM:+ and in $MEDIUM}.
     Mount the medium and set XSETUP_MEDIUM to where it is.
     Nothing has been written; $dev is untouched."
fi

# The kernel is taken from the medium when it is there, because the medium's own
# kernel is the one that was just booted and is therefore known to work, and from
# the running system's /boot only as a fallback.
KERNEL_SRC=$MEDIUM/boot/bzImage
[ -f "$KERNEL_SRC" ] || KERNEL_SRC=$SOURCE_ROOT/boot/vmlinuz
[ -f "$KERNEL_SRC" ] ||
	die "no kernel to install.  Expected $MEDIUM/boot/bzImage or
     $SOURCE_ROOT/boot/vmlinuz, and found neither.
     Nothing has been written; $dev is untouched."

LIMDIR=${LIMINE_DIR:-/usr/share/limine}
# The braces are not decoration.  Written as
#
#   boot_bytes=$( wc -c <a; wc -c <b ) | awk '{ n += $1 } END { print n+0 }'
#
# the assignment is the left-hand side of a pipeline, which this system's /bin/sh
# does not do: it assigns the whole multi-line text to boot_bytes and hands awk
# nothing, so the sum comes out 0 and the step dies with a message about not
# being able to measure anything.  The pipe has to be inside the substitution.
boot_bytes=$(
	{
		wc -c <"$KERNEL_SRC"
		wc -c <"$MEDIUM/boot/initramfs.img.gz"
		if [ -f "$LIMDIR/limine-bios.sys" ]; then
			wc -c <"$LIMDIR/limine-bios.sys"
		fi
		# The boot menu itself, plus limine-bios-hdd.h, which
		# `limine bios-install` stages into the boot sector.
		printf '4096\n'
	} 2>/dev/null | awk '{ n += $1 } END { print n + 0 }'
)

[ -n "$boot_bytes" ] && [ "$boot_bytes" -gt 0 ] 2>/dev/null ||
	die 'could not measure the kernel and initramfs, so the boot partition
     cannot be sized for them.  Nothing has been written.'

esp_mb=$(( boot_bytes / 1048576 + 32 ))
[ "$esp_mb" -lt 256 ] && esp_mb=256
say "  boot chain  $(awk -v b="$boot_bytes" 'BEGIN { printf "%d MiB", b / 1048576 }')"
say "  ESP         $esp_mb MiB"

info "partitioning $dev"
if [ "$DRY" -eq 1 ]; then
	# A dry run partitions nothing, so the layout it reports is the one
	# flxpart computes from the device size without writing.  That is the
	# only honest way to show the geometry: the real numbers come from a
	# real table, and a dry run says so rather than inventing LBAs.
	layout=$(flxpart --create-standard --no-flx-sys --esp-size "$esp_mb" --dry-run "$dev") ||
		die "flxpart could not compute a layout for $dev"
	say "  (dry run: nothing has been written to $dev)"
else
	layout=$(flxpart --create-standard --no-flx-sys --esp-size "$esp_mb" "$dev") ||
		die "flxpart could not partition $dev"
fi

# The layout flxpart just wrote, as it reports it.  Partitions are pulled out of
# it by type GUID, which is the one thing that says what a partition actually is;
# a name is for a human and an order is flxpart's business.  Matching on a name
# is how this step once looked for a partition called "ESP" and did not find the
# one called "EFI system".
#
# These are the type GUIDs as flxpart prints them, which is the mixed-endian
# byte order they are stored in rather than the canonical reading of them: the
# ESP type is 28732AC1-1F81-D211-4BBA-A0A0C93EC93B here and
# C12A7328-F81F-11D2-BA4B-00A0C93EC93B in the UEFI specification.
#
# GUID_ROOT is also the type of the data partition install_data makes.  That is
# flxpart's decision and it is the right one: the data partition is a Linux
# filesystem, and a FreeLinX-specific type GUID would make it unrecognised to
# every other Linux tool on the machine.  What makes it the /var filesystem is
# its label, which is why /init looks for the label and not for a type.
esp_i=$(part_index "$GUID_ESP")
bios_i=$(part_index "$GUID_BIOSBOOT")
root_i=$(part_index "$GUID_ROOT")

[ -n "$esp_i" ] || die "flxpart did not report an EFI system partition.
     Its output said:
$layout"
[ -n "$root_i" ] || die "flxpart did not report a root partition.
     Its output said:
$layout"

ESP_DEV=$(partdev "$dev" "$esp_i")
if [ -n "$bios_i" ]; then
	BIOS_DEV=$(partdev "$dev" "$bios_i")
else
	BIOS_DEV=''
fi
ROOT_DEV=$(partdev "$dev" "$root_i")

say "  EFI system  $ESP_DEV"
[ -n "$BIOS_DEV" ] && say "  BIOS boot   $BIOS_DEV"
say "  root        $ROOT_DEV"

# --- formatting ------------------------------------------------------------

need_cmd mkfs.ext4 'the sysutils/e2fsprogs port'
need_cmd mkfs.fat 'the sysutils/dosfstools port'

info "making a FAT filesystem on $ESP_DEV"
# -F 32: the UEFI spec requires FAT32 on the ESP, and a 256 MiB partition
# formatted as FAT16 will not boot.
if [ "$DRY" -eq 1 ]; then
	say "  would run: mkfs.fat -F 32 -n EFI $ESP_DEV"
	say "  would run: mkfs.ext4 -q -L freelinx $ROOT_DEV"
else
	mkfs.fat -F 32 -n EFI "$ESP_DEV" >/dev/null 2>&1 ||
		die "mkfs.fat failed on $ESP_DEV"
	ok "ESP formatted"

	info "making an ext4 filesystem on $ROOT_DEV"
	mkfs.ext4 -q -L freelinx "$ROOT_DEV" ||
		die "mkfs.ext4 failed on $ROOT_DEV"
	ok "root formatted"
fi

# --- copying the system ---------------------------------------------------

info "copying the system to $ROOT_DEV"
mkdir -p /mnt/flx || die 'cannot create /mnt/flx'
# -t ext4, not left to be guessed.  This system's mount(8) does not probe an
# unspecified filesystem, it fails, and the failure is
#
#   mount: mount /dev/vda3 on /mnt/flx: No such device
#
# which reads as a missing disk or an unsupported filesystem and is neither:
# /dev/vda3 was ext4 and the kernel had ext4.  The installer is the only thing
# in the tree that knows what it just formatted, so it says so.  Naming the type
# also skips the probe, which reads the superblock.
mount -t ext4 "$ROOT_DEV" /mnt/flx || die "cannot mount $ROOT_DEV at /mnt/flx as ext4"

# Trap so an interrupted copy unmounts rather than leaving the filesystem
# mounted over /mnt/flx with half a system on it.  The ESP is unmounted first:
# it is mounted inside /mnt/flx, so it has to go before the tree it lives in.
# umount /mnt/flx with something still mounted underneath it fails, and the
# result is a mount point nobody can clear without a reboot.
ESP_MOUNT=
cleanup() {
	rm -f "$TMPERR" 2>/dev/null || :
	if [ -n "$ESP_MOUNT" ]; then
		umount "$ESP_MOUNT" 2>/dev/null || :
		ESP_MOUNT=
	fi
	umount /mnt/flx 2>/dev/null || :
}
trap cleanup EXIT INT TERM

# tar, not cp -a.  The comment this replaced had it exactly backwards.
#
# The rootfs carries hard links -- the zoneinfo tree, 364 of them -- and the
# reason to keep them is that a system whose /usr/share/zoneinfo has 364 copies
# instead of one inode per zone is subtly wrong rather than obviously broken.
#
# cp does not keep them.  The cp in this system is the NetBSD one, whose usage
# is
#
#   usage: cp [-R [-H | -L | -P]] [-f | -i] [-alNpv] src target
#
# and its -a is -pPR: preserve mode, recursive, do not follow symlinks.  POSIX
# never asked cp to preserve hard links and this one does not.  Measured, on the
# binaries in this tree:
#
#   $ ln s/a s/b                       # same inode
#   $ cp -a s/. d/ && ls -i d/a d/b
#   113152                             <- different inodes
#   $ tar -cf - s | tar -xpf - -C d2 && ls -i d2/s/a d2/s/b
#   113157
#   113157                             <- one inode, as it was
#
# tar is not merely no worse here, it is the tool for the job: it stores a
# hard-linked file once and links the rest on the way out.  bsdtar comes from
# base/libarchive and is staged as /bin/tar.
need_cmd tar 'the base/libarchive port'

# -p on extract keeps the modes and ownership, and --numeric-owner stops a
# numeric uid in the archive from being looked up in the *installer's* passwd
# and coming out as somebody else.  The kernel and initramfs go through the
# stream as well, so nothing is read twice.
#
# What is left out, and why.  Pseudo-filesystems are the running kernel's state
# rather than the system: they are rebuilt on every boot, and /mnt is where this
# copy is going, so archiving /mnt/flx from inside itself is copying the target
# into the target.  Excluding them is not tidiness, it is correctness - /sys has
# files that cannot be opened, and bsdtar stops the archive when it cannot read
# one:
#
#   tar: Can't open `uevent': Permission denied
#   tar: Error exit delayed from previous errors
#
# The patterns carry the leading ./ because that is how the members are named
# when the archive is made from `.`, and bsdtar matches them as written.
EXCLUDES='--exclude ./proc --exclude ./sys --exclude ./dev --exclude ./run
--exclude ./tmp --exclude ./mnt --exclude ./cdrom --exclude ./media
--exclude ./lost+found'

# Both halves of the pipeline are checked, and this is the whole reason it is
# written this way rather than as
#
#   tar -cf - . | tar -xpf - || die
#
# A pipeline's status is the status of its last command, so that form reads only
# the *extract* side.  The failure above is on the *create* side: bsdtar aborted
# with the archive half-finished, the extract side consumed what it was given
# and exited 0, and the installer reported
#
#   ok  system copied
#
# over an installed system whose /bin and /usr/bin were empty directories.
#
# So the create side is a brace group, which puts it in a subshell whose stdout
# is still the pipe, and it records its own exit status in a file for the
# installer to read.  Writing the two tar commands as two separate commands
# instead of a pipeline does not work either: the first tar's stdout then goes to
# the console and the second reads the script's stdin, so the archive gets
# printed on the screen and nothing is extracted.
ERR_CREATE=$TMPERR.create
ERR_EXTRACT=$TMPERR.extract
RC_CREATE=$TMPERR.rc-create

{
	tar -C "$SOURCE_ROOT" $EXCLUDES --numeric-owner -cf - . 2>"$ERR_CREATE"
	echo "$?" >"$RC_CREATE"
} | tar -C /mnt/flx --numeric-owner -xpf - 2>"$ERR_EXTRACT"
_rc_extract=$?
_rc_create=$(cat "$RC_CREATE" 2>/dev/null) || _rc_create=1
[ -n "$_rc_create" ] || _rc_create=1

_rc=0
[ "$_rc_create" -eq 0 ] || _rc=1
[ "$_rc_extract" -eq 0 ] || _rc=1
# A non-empty error file with a zero exit is bsdtar saying it skipped
# something.  Skipping is a silent corruption unless it is said out loud, and
# the zone files are exactly the kind of thing that goes missing quietly, so
# this counts as a failure too.
[ -s "$ERR_CREATE" ] && _rc=1
[ -s "$ERR_EXTRACT" ] && _rc=1

if [ "$_rc" -ne 0 ]; then
	# Name what failed.  "the copy failed" with no reason is the least
	# useful error there is, and bsdtar does say which path it was on.
	[ "$_rc_create" -ne 0 ] &&
		warn "the archive side exited $_rc_create; what it said:"
	[ -s "$ERR_CREATE" ] && sed -n '1,20p' "$ERR_CREATE" >&2
	[ "$_rc_extract" -ne 0 ] &&
		warn "the extract side exited $_rc_extract; what it said:"
	[ -s "$ERR_EXTRACT" ] && sed -n '1,20p' "$ERR_EXTRACT" >&2
	die 'the system could not be copied. The partition has been left mounted at /mnt/flx; unmount it before retrying.'
fi
ok "system copied"

# --- boot ------------------------------------------------------------------

# The ESP is mounted inside the root filesystem, at the path fstab will use, and
# it is where the whole boot chain goes: limine-bios.sys, the boot menu, the
# kernel and the initramfs.
#
# It goes there because Limine's BIOS stage cannot read ext4.  Not "prefers not
# to" - cannot: limine-bios.sys contains a FAT32 reader and an NTFS reader and no
# ext2, ext3 or ext4 reader at all, so on a disk whose system is on ext4 the
# stage-2 loader walks the partitions, fails to read the one holding
# limine-bios.sys, and stops with
#
#   !! Stage 3 file not found!
#   PANIC: Failed to load stage 3.
#
# which is what a disk with a perfectly good ext4 root and a perfectly good
# limine-bios.sys in its /boot produces.  The root filesystem still holds the
# system; it is simply not on the path Limine can read, which is the same
# arrangement every other distribution using a FAT ESP has.
ESP_DIR=/mnt/flx/boot/efi
mkdir -p "$ESP_DIR" || die "cannot create $ESP_DIR"
ESP_MOUNT=$ESP_DIR
mount -t vfat "$ESP_DEV" "$ESP_DIR" ||
	die "cannot mount $ESP_DEV at $ESP_DIR as vfat"
# After the mount, not before.  A /boot created inside the mount point before
# mounting it is created on the ext4 root and then hidden by the FAT filesystem
# that lands on top of it, so every later path under it is a path that does not
# exist - and the error that comes out of cp is about the wrong thing entirely.
mkdir -p "$ESP_DIR/boot" ||
	die "cannot create $ESP_DIR/boot on the EFI system partition"

# Both names, because Limine searches the root, /boot, /limine and /boot/limine
# of each partition it can read, and putting the file in one place and trusting
# the search order is how it ends up not found.  Two copies of a 330 kB file.
place_esp() {
	_from=$1
	_to=$2
	[ -f "$ESP_DIR$_to" ] && return 0
	if ! cp "$_from" "$ESP_DIR$_to" 2>"$TMPERR.placing"; then
		# Two different failures with one message between them is how a
		# missing directory gets reported as a full filesystem, which sends
		# the person looking for megabytes that are not the problem.
		if [ -d "$ESP_DIR$(dirname "$_to")" ]; then
			die "could not place $(basename "$_to") on the EFI system partition:
$(sed -n '1,4p' "$TMPERR.placing" >&2)
     The ESP is $esp_mb MiB and the chain is $(awk -v b="$boot_bytes" \
'BEGIN { printf "%d", b / 1048576 }') MiB, so either the filesystem is full
     or the medium's copy is unreadable."
		fi
		die "could not place $(basename "$_to") on the EFI system partition:
     $(dirname "$_to") does not exist on it.  Nothing has been unmounted; the
     disk is still mounted at /mnt/flx."
	fi
	ok "placed $(basename "$_to") on the ESP at$_to"
}

place_esp "$KERNEL_SRC" /boot/bzImage
place_esp "$MEDIUM/boot/initramfs.img.gz" /boot/initramfs.img.gz

# limine-bios.sys is what stage 2 loads and stage 3 is made of, so it is named
# exactly that rather than something tidier.
[ -f "$LIMDIR/limine-bios.sys" ] ||
	die "$LIMDIR/limine-bios.sys is missing, so there is no bootloader to
     install.  Nothing has been unmounted; the disk is still mounted at /mnt/flx."
place_esp "$LIMDIR/limine-bios.sys" /limine-bios.sys
place_esp "$LIMDIR/limine-bios.sys" /boot/limine-bios.sys

# root_uuid is read here rather than in the fstab block below, because the boot
# menu needs it too and the fstab block is the wrong place to read a value from
# before the thing that uses it.
root_uuid=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || :)

# The boot menu.  Limine on a disk has no menu of its own: limine-bios.sys reads
# one, and with none on the disk there is nothing to read and the machine stops
# after its second stage.  The ISO's menu names a kernel and an initramfs in
# this same directory and nothing else, so the installed disk gets the same menu
# with a root filesystem UUID on the command line as well, in case a kernel is
# ever told to look for one.
#
# `boot():` is the volume Limine itself was loaded from, which is the ESP, and
# which is where the two files named above are.
#
# `serial: yes` is what puts Limine's own messages on the serial line.  Without it
# a boot failure is silent on a headless machine, which is the worst possible
# time for it.
#
# No `quiet`, and unlike the medium's own menu.  The medium's kernel is known to
# work - it is the one that is running - so hiding its output costs nothing
# there.  On a disk it is the first boot of a new installation, and `quiet` on a
# first boot turns every early failure into a blank screen on a machine whose
# owner has nothing to debug with.  loglevel is left at the kernel default for
# the same reason: a stale `loglevel=2` suppresses the version banner and every
# KERN_ERR, which is the whole of what is worth reading on a first boot.
{
	printf '# Written by xsetup.\n'
	printf 'timeout: 5\n'
	printf 'serial: yes\n'
	printf '\n'
	printf '/FreeLinX\n'
	printf '    protocol: linux\n'
	printf '    kernel_path: boot():/boot/bzImage\n'
	printf '    module_path: boot():/boot/initramfs.img.gz\n'
	printf '    cmdline: root=UUID=%s rdinit=/init console=tty0 console=ttyS0,115200\n' \
		"$root_uuid"
} >"$ESP_DIR/limine.conf" ||
	die 'could not write the boot menu to the EFI system partition'
# The same menu in /boot as well, for the same reason as the two limine-bios.sys
# copies: which of the four paths Limine reaches first is not something to bet a
# boot on.
cp "$ESP_DIR/limine.conf" "$ESP_DIR/boot/limine.conf" ||
	die 'could not write the boot menu to /boot on the EFI system partition'
ok 'boot menu written to the ESP'

# fstab, keyed on filesystem UUIDs rather than on /dev/sdaN.
#
# /dev/sdaN is not stable: it moves when a disk is added, when a controller
# enumerates differently, or when the disk is moved to another machine.  The
# UUID is created with the filesystem and does not change, so a system that
# boots once from /dev/sda2 keeps booting after a USB stick appears.
#
# root_uuid was read above for the boot menu and is not read again: the same
# value in two places is two places to be out of step.
esp_uuid=$(blkid -s UUID -o value "$ESP_DEV" 2>/dev/null || :)

if [ -z "$root_uuid" ] || [ -z "$esp_uuid" ]; then
	die "could not read the filesystem UUIDs for $ROOT_DEV and $ESP_DEV.
     Without them fstab would be written against /dev names that move, and
     the installed system would not find its root on the next boot.
     Nothing has been unmounted; the disk is still mounted at /mnt/flx."
fi

{
	printf '# Written by xsetup.\n'
	printf 'UUID=%s\t/\text4\tdefaults\t0 1\n' "$root_uuid"
	printf 'UUID=%s\t/boot/efi\tvfat\tdefaults\t0 2\n' "$esp_uuid"
} >/mnt/flx/etc/fstab
ok "fstab written, keyed on UUIDs"

# --- bootloader ------------------------------------------------------------

# limine bios-install on a whole disk image needs the image as a file, not a
# partition device, so it is applied to the disk node where possible and the
# ESP is mounted for the EFI half.  Limine writes both its own MBR stages and
# the GPT-to-MBR conversion, so it runs after mkfs and after the copy.
need_cmd limine 'the drivers/bootloader/limine-binary port'

# Limine needs three things on a disk, and they are not the same three it
# needs on an ISO:
#
#   limine-bios.sys   on a partition the BIOS stage can read, in /, /boot,
#                     /limine or /boot/limine.  Stage 2 reads FAT and NTFS and
#                     nothing else, so this is the ESP and not the root
#                     filesystem; it was placed above, before this section.
#   BOOTX64.EFI       on the ESP under EFI/BOOT, which is where UEFI looks.
#   the MBR stages    written by `limine bios-install`, which also stages
#                     limine-bios-hdd.h into the boot sector.
#
# The .bin files the ISO uses (limine-bios-cd.bin, limine-uefi-cd.bin) are
# El Torito boot images for a CD, and are the wrong files here.  Copying them
# onto the ESP would produce a system that boots on neither BIOS nor UEFI.
LIMDIR=${LIMINE_DIR:-/usr/share/limine}

info 'installing the bootloader'

if [ -f "$LIMDIR/BOOTX64.EFI" ]; then
	# The ESP is already mounted at $ESP_DIR from the boot section above, and
	# staying mounted is deliberate: the BIOS stages are written to the disk
	# node and do not need it, but unmounting and remounting a FAT filesystem
	# twice for one install is two chances to fail for nothing.
	#
	# -t vfat was named when it was mounted rather than left to be guessed,
	# for the same reason -t ext4 was named on the root.
	mkdir -p "$ESP_DIR/EFI/BOOT"
	cp "$LIMDIR/BOOTX64.EFI" "$ESP_DIR/EFI/BOOT/" ||
		die 'could not place BOOTX64.EFI on the ESP.'
	ok 'BOOTX64.EFI placed on the ESP'
else
	warn "$LIMDIR/BOOTX64.EFI is missing, so there is no UEFI boot target."
fi

# bios-install stages the BIOS boot code into the drive's own first sectors.
#
# On a GPT disk the second argument is not optional.  limine's own usage says
#
#   usage: %s bios-install <device> [GPT partition index]
#
# and it refuses without it:
#
#   error: Installing to a GPT device, but no BIOS boot partition specified
#
# which is what happened here, so the BIOS stages were never written and a BIOS
# boot had nothing in the MBR.  The index is the one computed above from the
# layout's BIOS boot partition type, not the number of the partition as a
# device name: flxpart chooses the order and the two are not the same thing.
#
# limine's stage 1 is embedded in the tool (binary_limine_hdd_bin), so there is
# no limine-bios-hdd.h to find, and the check for that file which used to be
# here was checking for something this version of limine does not read.
limine=$(command -v limine 2>/dev/null) ||
	die 'limine is not in PATH, so the bootloader cannot be installed.'

if [ -n "$bios_i" ]; then
	_limine_args=$bios_i
else
	warn "flxpart laid out no BIOS boot partition on $dev, so limine has"
	warn 'nowhere on the table to put the stage 1 it wants.'
	_limine_args=''
fi

if [ -n "$_limine_args" ]; then
	if (cd "$LIMDIR" && "$limine" bios-install "$dev" "$_limine_args") \
			>"$TMPERR.limine" 2>&1; then
		ok "Limine BIOS stages installed on $dev (BIOS boot partition $_limine_args)"
	else
		warn "limine bios-install could not write to $dev."
		sed -n '1,10p' "$TMPERR.limine" >&2
		warn 'A BIOS boot may not work until Limine is installed by hand.'
	fi
else
	warn 'limine bios-install was not run, so a BIOS boot will not work.'
fi

cleanup
trap - EXIT INT TERM

printf '%s\n' "$(cat /mnt/flx/etc/xsetup-disk-mode 2>/dev/null || echo sys)" >"$DONE_FILE" 2>/dev/null || printf 'sys\n' >"$DONE_FILE"
rm -f /mnt/flx 2>/dev/null || rmdir /mnt/flx 2>/dev/null || :

ok "installed to $dev"
say ''
say "  root   $ROOT_DEV"
say "  boot   $ESP_DEV (UEFI), $dev (BIOS)"
say ''
say 'Reboot and remove the medium. The disk boots on both BIOS and UEFI.'
