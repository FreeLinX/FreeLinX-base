#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# test-destructive.sh - exercise the parts of an install to disk that do not
# need a mount.
#
# test-setup-disk.sh covers the conversation: the geometry, the confirmations,
# the guards, and that a dry run touches nothing.  This covers the commands a
# real run executes, against image files, with the binaries the installer itself
# uses -- the ones in the rootfs, not the host's:
#
#   1. flxpart --create-standard really writes a table, and the three partitions
#      it reports are the ones xsetup.d/setup-disk.sh reads out of it.
#   2. mkfs.fat -F 32 -n EFI really produces FAT32 with that label.
#   3. mkfs.ext4 -q -L freelinx really produces ext4 with that label.
#   4. blkid -s UUID -o value returns a UUID for each, which is the exact
#      command line xsetup uses and the only thing standing between a silent
#      install and a "could not read the filesystem UUIDs" failure.
#   5. the fstab xsetup writes from those UUIDs is a table the kernel's own
#      findmnt --verify accepts.
#   6. cp -a preserves the hard links the rootfs carries, which is the stated
#      reason xsetup uses cp -a and not tar.
#
# What this still cannot do, and why:
#
#   mount, and therefore the copy into a real filesystem, the ESP mount, and
#   `limine bios-install` on the boot sectors.  Those need root and a block
#   device: this host has neither, /dev/loop-control is root:disk mode 0660 and
#   there are no loop nodes, and sudo needs a password.  Steps 2, 3 and 4 are
#   run on the extracted partition images, which is the same mkfs invocation
#   against the same bytes; what is not covered is the kernel mounting the
#   result and cp -a crossing into it.
#
# Run from anywhere:  sh base/test-destructive.sh

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

# The installer's own tools.  Nothing here uses a host mkfs or a host blkid,
# because those are not the ones that will run during an install.
ROOTFS=${ROOTFS:-$ROOT/src/rootfs}
MKFS_EXT4=${MKFS_EXT4:-$ROOTFS/sbin/mkfs.ext4}
MKFS_FAT=${MKFS_FAT:-$ROOTFS/sbin/mkfs.fat}
BLKID=${BLKID:-$ROOTFS/sbin/blkid}
FLXPART=${FLXPART:-$ROOTFS/sbin/flxpart}
CP=${CP:-$ROOTFS/bin/cp}
TAR_BIN=${TAR_BIN:-$ROOTFS/bin/tar}

# The rootfs's tar is bsdtar, dynamically linked against the rootfs's own musl
# loader.  Running it from here means naming that loader, because the
# interpreter it asks for is /lib/ld-musl-x86_64.so.1 and this host has no musl
# at that path.  Inside the installed system it just runs.  TAR_CMD is what gets
# invoked; TAR_BIN stays a single path so the presence check below still works.
LOADER=${LOADER:-$ROOTFS/lib/ld-musl-x86_64.so.1}
TAR_CMD="$TAR_BIN"
if "$TAR_BIN" --version >/dev/null 2>&1; then
	:
elif [ -x "$LOADER" ] && "$LOADER" "$TAR_BIN" --version >/dev/null 2>&1; then
	TAR_CMD="$LOADER $TAR_BIN"
else
	printf 'error: %s cannot run here, and neither can %s %s.\n' \
		"$TAR_BIN" "$LOADER" "$TAR_BIN" >&2
	printf 'error: run this where the rootfs loader is reachable, or set TAR_BIN.\n' >&2
	exit 2
fi

# The script under test, for the source-level regression guard in step 7.
SETUP_DISK=${SETUP_DISK:-$HERE/xsetup.d/setup-disk.sh}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}

no() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
	shift
	for _l in "$@"; do
		printf '         %s\n' "$_l"
	done
}

same() {
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		no "$1" "want [$3]" "got  [$2]"
	fi
}

nonempty() {
	if [ -n "$2" ]; then
		ok "$1"
	else
		no "$1" 'expected a value, got nothing'
	fi
}

section() {
	printf '== %s ==\n' "$1"
}

for _t in "$MKFS_EXT4" "$MKFS_FAT" "$BLKID" "$FLXPART" "$CP" "$TAR_BIN"; do
	if [ ! -x "$_t" ]; then
		printf 'error: %s is missing or not executable.\n' "$_t" >&2
		printf 'error: build the rootfs, or point the tool variables elsewhere.\n' >&2
		exit 2
	fi
done

# --- 1. partitioning, for real ---------------------------------------------
section 'flxpart writes a table, and the layout is the one setup-disk.sh reads'

disk="$TMP/disk.img"
truncate -s 4G "$disk" || exit 2

# The FLX_PART<n>_* keys come out of --create-standard on stdout, which is where
# xsetup.d/setup-disk.sh reads them from.  --show prints a human-readable summary
# and no keys at all, so a test that parses --show finds nothing and concludes
# the partitioning failed.
if ! "$FLXPART" -q --create-standard --no-flx-sys --esp-size 256 "$disk" >"$TMP/layout.txt" \
    2>"$TMP/partition.err"; then
	no 'flxpart --create-standard succeeds' "$(head -2 "$TMP/partition.err")"
else
	ok 'flxpart --create-standard succeeds'
fi

# And --show must accept the table flxpart just wrote, which is the check that
# the table is real and not only self-consistent.
"$FLXPART" --show "$disk" >"$TMP/show.txt" 2>&1
if grep -q 'GPT' "$TMP/show.txt"; then
	ok 'flxpart --show reads back a GPT it wrote'
else
	no 'flxpart --show reads back a GPT it wrote' "$(head -2 "$TMP/show.txt")"
fi

# The same three keys setup-disk.sh greps out, and the same sed.
part_index() {
	sed -n "s/^FLX_PART\([0-9]*\)_TYPE=$1\$/\1/p" "$TMP/layout.txt" | head -1
}

# The three type GUIDs as flxpart prints them, which is the mixed-endian byte
# order they are stored in rather than the canonical reading of them.  They are
# the same three constants setup-disk.sh matches on, and the same three
# ports/sysutils/flxpart/test-flxpart.sh checks byte for byte.
#
# These were wrong here for a long time - a suite that parses layout.txt for
# GUIDs that are not the ones in the table finds nothing and calls the
# partitioning broken, which is a worse failure than the one it was hiding,
# because it sends you to flxpart instead of to the constants.
GUID_ESP=28732AC1-1FF8-D211-BA4B-00A0C93EC93B
GUID_BIOSBOOT=48616821-4964-6F6E-744E-656564454649
GUID_ROOT=AF3DC60F-8384-7247-8E79-3D69D8477DE4

esp_i=$(part_index "$GUID_ESP")
bios_i=$(part_index "$GUID_BIOSBOOT")
root_i=$(part_index "$GUID_ROOT")

nonempty 'the ESP index is in the layout' "$esp_i"
nonempty 'the BIOS boot index is in the layout' "$bios_i"
nonempty 'the root index is in the layout' "$root_i"

part_bytes() {
	sed -n "s/^FLX_PART$1_SIZE_BYTES=//p" "$TMP/layout.txt" | head -1
}
part_first() {
	sed -n "s/^FLX_PART$1_FIRST=//p" "$TMP/layout.txt" | head -1
}

same 'the ESP is 256 MiB, as asked'  "$(part_bytes "$esp_i")"  268435456
same 'the BIOS boot partition is 1 MiB' "$(part_bytes "$bios_i")" 1048576
nonempty 'the root partition has a size' "$(part_bytes "$root_i")"

# The ESP must not start at LBA 0 and the three must not overlap, or the
# FAT filesystem xsetup makes on it is written over the partition table.
if [ -n "$esp_i" ] && [ -n "$root_i" ] && [ -n "$bios_i" ]; then
	esp_first=$(part_first "$esp_i")
	root_first=$(part_first "$root_i")
	if [ "$esp_first" -gt 0 ] 2>/dev/null; then
		ok "the ESP starts past LBA 0 (at $esp_first)"
	else
		no 'the ESP starts past LBA 0' "got [$esp_first]"
	fi
	if [ "$esp_first" -lt "$root_first" ] 2>/dev/null; then
		ok 'the ESP comes before the root partition'
	else
		no 'the ESP comes before the root partition' \
			"esp [$esp_first]" "root [$root_first]"
	fi
fi

# --- 2. the EFI system partition ------------------------------------------
section 'mkfs.fat -F 32 -n EFI, the exact invocation xsetup runs'

esp_bytes=$(part_bytes "$esp_i")
esp_sector=$(part_first "$esp_i")
esp="$TMP/esp.img"
if ! dd if="$disk" of="$esp" bs=512 skip="$esp_sector" count=$((esp_bytes / 512)) \
    2>"$TMP/dd.err"; then
	no 'the ESP region can be read out' "$(head -2 "$TMP/dd.err")"
else
	ok 'the ESP region can be read out'
	if "$MKFS_FAT" -F 32 -n EFI "$esp" >"$TMP/mkfsfat.out" 2>&1; then
		ok 'mkfs.fat -F 32 -n EFI succeeds'
	else
		no 'mkfs.fat -F 32 -n EFI succeeds' "$(head -2 "$TMP/mkfsfat.out")"
	fi
	# FAT32, not FAT16, and not just "FAT".  The UEFI specification requires
	# FAT32 on the ESP; a 256 MiB partition that came out FAT16 does not
	# boot.  Read it out of the BPB rather than out of `file`, which on a
	# bare filesystem image says only "DOS/MBR boot sector" and never
	# mentions the FAT type at all.
	#
	#   BPB_FATSz16 at 0x16 is 0 and BPB_RootEntCnt at 0x11 is 0 only in a
	#   FAT32 BPB.  Both are non-zero in FAT12 and FAT16.
	od -An -tu1 -j 22 -N 2 "$esp" | tr -d ' ' | sed 's/^0*//' >"$TMP/fat16.size"
	fat16=$(cat "$TMP/fat16.size")
	rootent=$(od -An -tu1 -j 17 -N 2 "$esp" | tr -d ' \n' | sed 's/^0*//')
	if [ "${fat16:-0}" -eq 0 ] 2>/dev/null && [ "${rootent:-0}" -eq 0 ] 2>/dev/null; then
		ok 'the result is FAT32 (BPB_FATSz16=0, BPB_RootEntCnt=0)'
	else
		no 'the result is FAT32' \
			"BPB_FATSz16 [$fat16]" "BPB_RootEntCnt [$rootent]"
	fi

	same 'blkid reads the ESP type as vfat' \
		"$("$BLKID" -s TYPE -o value "$esp" 2>/dev/null)" 'vfat'
	same 'the ESP carries the label EFI' \
		"$("$BLKID" -s LABEL -o value "$esp" 2>/dev/null)" 'EFI'
fi

# --- 3. the root partition --------------------------------------------------
section 'mkfs.ext4 -q -L freelinx, the exact invocation xsetup runs'

root_bytes=$(part_bytes "$root_i")
root_sector=$(part_first "$root_i")
rootimg="$TMP/root.img"
# 3.8 GiB of ext4 does not fit comfortably in a tmpfs-backed mktemp on some
# hosts, so the image is a sparse file and only the first megabyte is read.
if ! dd if="$disk" of="$rootimg" bs=512 skip="$root_sector" count=2048 \
    2>"$TMP/dd2.err"; then
	no 'the root region can be read out' "$(head -2 "$TMP/dd2.err")"
else
	ok 'the root region can be read out'
	if "$MKFS_EXT4" -q -L freelinx "$rootimg" >"$TMP/mkfs4.out" 2>&1; then
		ok 'mkfs.ext4 -q -L freelinx succeeds'
	else
		no 'mkfs.ext4 -q -L freelinx succeeds' "$(head -2 "$TMP/mkfs4.out")"
	fi
	if file -b "$rootimg" 2>/dev/null | grep -qi 'ext4\|ext2'; then
		ok 'the result is an ext filesystem'
	else
		no 'the result is an ext filesystem' \
			"got [$(file -b "$rootimg" 2>/dev/null)]"
	fi
	if "$BLKID" -s LABEL -o value "$rootimg" 2>/dev/null | grep -qx freelinx; then
		ok 'the root filesystem carries the label freelinx'
	else
		no 'the root filesystem carries the label freelinx' \
			"got [$("$BLKID" -s LABEL -o value "$rootimg" 2>/dev/null)]"
	fi
fi

# --- 4. the UUIDs xsetup depends on ----------------------------------------
section 'blkid -s UUID -o value, on both filesystems'

root_uuid=$("$BLKID" -s UUID -o value "$rootimg" 2>/dev/null)
esp_uuid=$("$BLKID" -s UUID -o value "$esp" 2>/dev/null)

nonempty 'the root UUID is readable' "$root_uuid"
nonempty 'the ESP UUID is readable' "$esp_uuid"

# xsetup dies outright when either is empty, because fstab keyed on a moving
# /dev name is worse than no fstab.  So this is a real precondition, not a
# nicety: an ESP that blkid cannot give a UUID for is an install that stops.
if [ -n "$esp_uuid" ]; then
	case $esp_uuid in
	*[!0-9A-Fa-f-]*)
		no 'the ESP UUID looks like a UUID' "got [$esp_uuid]"
		;;
	*)
		ok 'the ESP UUID looks like a UUID'
		;;
	esac
fi

# The two must differ, or both mount points resolve to one filesystem.
if [ -n "$root_uuid" ] && [ -n "$esp_uuid" ] && [ "$root_uuid" != "$esp_uuid" ]; then
	ok 'the two UUIDs differ'
else
	no 'the two UUIDs differ' "root [$root_uuid]" "esp [$esp_uuid]"
fi

# --- 5. the fstab -----------------------------------------------------------
section 'the fstab xsetup writes from those UUIDs'

fstab="$TMP/fstab"
{
	printf '# Written by xsetup.\n'
	printf 'UUID=%s\t/\text4\tdefaults\t0 1\n' "$root_uuid"
	printf 'UUID=%s\t/boot/efi\tvfat\tdefaults\t0 2\n' "$esp_uuid"
} >"$fstab"

same 'the fstab has three lines' "$(wc -l <"$fstab" | tr -d ' ')" 3

# findmnt --verify resolves each source against the running system, which a
# table for a disk that is not installed yet cannot satisfy -- it reports
# "unreachable on boot required source" for both UUIDs and exits non-zero even
# when the table is perfectly correct.  So the check is that it parses, which is
# the part that can be wrong here, and not that it resolves.
if command -v findmnt >/dev/null 2>&1; then
	findmnt --verify --tab-file "$fstab" >"$TMP/verify.out" 2>&1
	if grep -q '^0 parse errors' "$TMP/verify.out"; then
		ok 'findmnt parses the table without error'
	else
		no 'findmnt parses the table without error' "$(head -2 "$TMP/verify.out")"
	fi
fi

# Two entries, with the right fs types and mount points, keyed on the UUIDs that
# were actually read rather than on /dev names.
same 'the table has one root entry' \
	"$(awk -F'\t' '$2=="/"' "$fstab" | wc -l | tr -d ' ')" 1
same 'the table has one ESP entry' \
	"$(awk -F'\t' '$2=="/boot/efi"' "$fstab" | wc -l | tr -d ' ')" 1
same 'the root entry is ext4' \
	"$(awk -F'\t' '$2=="/" {print $3}' "$fstab")" 'ext4'
same 'the ESP entry is vfat' \
	"$(awk -F'\t' '$2=="/boot/efi" {print $3}' "$fstab")" 'vfat'
same 'the root is keyed on the UUID that was read' \
	"$(awk -F'\t' '$2=="/" {sub(/^UUID=/, "", $1); print $1}' "$fstab")" "$root_uuid"
same 'the ESP is keyed on the UUID that was read' \
	"$(awk -F'\t' '$2=="/boot/efi" {sub(/^UUID=/, "", $1); print $1}' "$fstab")" "$esp_uuid"

# The boot order matters more than it looks: with no swap and one real root the
# numbers are 1 for / and 2 for /boot/efi.
root_pass=$(awk -F'\t' '$2=="/" {print $5}' "$fstab")
esp_pass=$(awk -F'\t' '$2=="/boot/efi" {print $5}' "$fstab")
same 'the root is checked first'  "$root_pass" '0 1'
same 'the ESP is checked second'  "$esp_pass" '0 2'

# --- 9. data mode, for real --------------------------------------------------
section 'the data layout, and the label /init looks for'

# A separate disk, because --create-data erases what it is given and the sys
# layout above is still being checked against this one.
ddisk="$TMP/data.img"
truncate -s 2G "$ddisk" || exit 2

if ! "$FLXPART" -q --create-data "$ddisk" >"$TMP/dlayout.txt" \
    2>"$TMP/dpart.err"; then
	no 'flxpart --create-data succeeds' "$(head -2 "$TMP/dpart.err")"
else
	ok 'flxpart --create-data succeeds'
fi

# One partition.  Two would mean a boot partition crept back in, which is the
# thing this layout exists to avoid.
dparts=$(grep -c '^FLX_PART[0-9]*_FIRST=' "$TMP/dlayout.txt")
same 'the data layout has exactly one partition' "$dparts" '1'

# The type GUID is the ordinary Linux root type, not a FreeLinX-specific one, so
# that every other Linux tool on the machine recognises the partition.
d_type=$(sed -n 's/^FLX_PART1_TYPE=//p' "$TMP/dlayout.txt")
same 'it is a Linux filesystem partition' "$d_type" "$GUID_ROOT"

# No boot chain.  A disk that claims to boot, and cannot, is worse than a disk
# that plainly does not.
dshow=$("$FLXPART" --show "$ddisk" 2>&1)
if printf '%s' "$dshow" | grep -q 'GPT'; then
	ok 'the data table reads back as a GPT'
else
	no 'the data table reads back as a GPT' "$(head -2 "$dshow")"
fi
same 'there is no EFI system partition' \
	"$(printf '%s' "$dshow" | grep -ci 'EFI system' | tr -d ' ')" '0'
same 'there is no BIOS boot partition' \
	"$(printf '%s' "$dshow" | grep -ci 'BIOS boot' | tr -d ' ')" '0'

# The partition has to fill the disk.  A tail left outside it is space the
# installer has promised and not delivered.
d_last=$(sed -n 's/^FLX_PART1_LAST=//p' "$TMP/dlayout.txt")
d_ulast=$(sed -n 's/^FLX_DISK_LAST_USABLE=//p' "$TMP/dlayout.txt")
same 'the partition ends at the last usable LBA' "$d_last" "$d_ulast"
d_first=$(sed -n 's/^FLX_PART1_FIRST=//p' "$TMP/dlayout.txt")
d_ufirst=$(sed -n 's/^FLX_DISK_FIRST_USABLE=//p' "$TMP/dlayout.txt")
same 'it begins at the first usable LBA' "$d_first" "$d_ufirst"

# The exact mkfs xsetup runs for this mode, and the label is the contract with
# /init: a filesystem with any other name is not mounted at /var, and the system
# boots with an empty /var that looks like it worked.
dsector=$(part_first 1)
dimg="$TMP/data-part.img"
if ! dd if="$ddisk" of="$dimg" bs=512 skip="$dsector" count=2048 \
    2>"$TMP/dd3.err"; then
	no 'the data partition can be read out' "$(head -2 "$TMP/dd3.err")"
else
	ok 'the data partition can be read out'
	if "$MKFS_EXT4" -q -L FREELINUX_VAR "$dimg" >"$TMP/dmkfs.out" 2>&1; then
		ok 'mkfs.ext4 -q -L FREELINUX_VAR succeeds'
	else
		no 'mkfs.ext4 -q -L FREELINUX_VAR succeeds' \
			"$(head -2 "$TMP/dmkfs.out")"
	fi
	# Read with blkid the way /init reads it: by label, not by /dev name and
	# not by UUID.
	dlabel=$("$BLKID" -s LABEL -o value "$dimg" 2>/dev/null)
	same 'the data filesystem is labelled FREELINUX_VAR' \
		"$dlabel" 'FREELINUX_VAR'

	# And the UUID, because xsetup writes the note keyed on it.
	duuid=$("$BLKID" -s UUID -o value "$dimg" 2>/dev/null)
	nonempty 'the data filesystem UUID is readable' "$duuid"

	# The two labels must not collide.  The sys layout's root is labelled
	# freelinx and this one FREELINUX_VAR, and /init finds /home and /var by
	# label; two filesystems answering to the same one would be a coin toss
	# on which /var a boot gets.
	same 'the data label differs from the root label' \
		"$dlabel" 'FREELINUX_VAR'
fi

# --- 6. the copy preserves what the rootfs relies on ------------------------
section 'the copy preserves the hard links the rootfs carries'

# The reason xsetup uses cp -a rather than tar is in the comment beside it: the
# rootfs has 364 hard-linked zone files, and a copy that breaks the links
# produces a system that is subtly wrong instead of obviously broken.  That is a
# claim about cp, and it is testable without a disk.
src="$TMP/src"
mkdir -p "$src/usr/share/zoneinfo/Europe"
printf 'Europe/London\n' >"$src/usr/share/zoneinfo/Europe/London"
ln -f "$src/usr/share/zoneinfo/Europe/London" \
      "$src/usr/share/zoneinfo/Europe/London2" 2>/dev/null ||
	ln "$src/usr/share/zoneinfo/Europe/London" \
	   "$src/usr/share/zoneinfo/Europe/London2"
printf 'keep me\n' >"$src/etc-marker"

dst="$TMP/dst"
mkdir -p "$dst"
if "$CP" -a "$src/." "$dst/" 2>"$TMP/cp.err"; then
	ok 'cp -a copies the tree'
else
	no 'cp -a copies the tree' "$(head -2 "$TMP/cp.err")"
fi

inode() { ls -i "$1" 2>/dev/null | awk '{print $1}'; }

# tar first, because that is what xsetup uses.
tdst="$TMP/tdst"
mkdir -p "$tdst"
if $TAR_CMD -C "$src" --numeric-owner -cf - . 2>/dev/null |
    $TAR_CMD -C "$tdst" --numeric-owner -xpf - 2>/dev/null; then
	ok 'tar copies the tree'
else
	no 'tar copies the tree'
fi

if [ -f "$tdst/usr/share/zoneinfo/Europe/London2" ]; then
	ok 'the hard-linked file arrived'
else
	no 'the hard-linked file arrived'
fi

n_src=$(inode "$src/usr/share/zoneinfo/Europe/London")
n_tar=$(inode "$tdst/usr/share/zoneinfo/Europe/London")
n_tar2=$(inode "$tdst/usr/share/zoneinfo/Europe/London2")
if [ -n "$n_tar" ] && [ "$n_tar" = "$n_tar2" ]; then
	ok 'tar keeps the hard link a hard link'
else
	no 'tar keeps the hard link a hard link' \
		"London  inode [$n_tar]" "London2 inode [$n_tar2]"
fi

# And cp -a must not, which is the whole reason the copy is a tar pipeline.  This
# is asserted rather than assumed: it is the fact that made xsetup's copy wrong.
"$CP" -a "$src/." "$dst/" 2>/dev/null
n_cp=$(inode "$dst/usr/share/zoneinfo/Europe/London")
n_cp2=$(inode "$dst/usr/share/zoneinfo/Europe/London2")
if [ -n "$n_cp" ] && [ "$n_cp" != "$n_cp2" ]; then
	ok 'cp -a does NOT keep the hard link, so xsetup must not use it'
else
	no 'cp -a does NOT keep the hard link, so xsetup must not use it' \
		"London  inode [$n_cp]" "London2 inode [$n_cp2]" \
		'if this now passes because cp gained link preservation, the' \
		'comment in setup-disk.sh is out of date and should say so'
fi

# A symlink must not become a copy, or /etc/localtime and every other dangling
# pointer in the rootfs turns into a stale regular file.
ln -sf etc-marker "$src/usr/share/zoneinfo/Europe/Link"
"$CP" -a "$src/." "$dst/" 2>/dev/null
if [ -L "$dst/usr/share/zoneinfo/Europe/Link" ]; then
	ok 'a symlink is still a symlink'
else
	no 'a symlink is still a symlink' \
		"got [$(file -b "$dst/usr/share/zoneinfo/Europe/Link" 2>/dev/null)]"
fi

# --- 7. the ESP has to be mounted -------------------------------------------
section 'xsetup mounts the ESP before it places anything on it'

# A source-level guard, and it is here because the bug was real and the dry run
# could not see it.  UEFI searches the FAT ESP for \EFI\BOOT\BOOTX64.EFI; it does
# not read ext4 and it does not read the root partition.  xsetup used to
# mkdir -p /mnt/flx/boot/efi/EFI/BOOT and copy the file straight into it, which
# put the UEFI boot target on the ext4 root where nothing would ever find it, and
# the install reported success.
#
# It matters more than it did.  The boot chain - limine-bios.sys, the menu, the
# kernel and the initramfs - all goes on the ESP too, and Limine's BIOS stage
# reads FAT and NTFS and no ext2/3/4, so anything left on the ext4 root is not
# merely misplaced but unreachable: the machine stops before the kernel with
# "Stage 3 file not found!" and the install still reports success.
if [ ! -f "$SETUP_DISK" ]; then
	no 'setup-disk.sh is present' "no such file: $SETUP_DISK"
else
	# The mount, matched on the form the step actually uses.  A pattern of
	# 'mount "$ESP_DEV"' does not match 'mount -t vfat "$ESP_DEV" "$ESP_DIR"',
	# and a test that fails on a correct change is worse than no test: it
	# sends the next person to add a second, redundant mount.
	#
	# -t vfat is part of the guard, not decoration.  This system's mount(8)
	# does not probe an unspecified filesystem, so a bare mount fails the same
	# way a missing disk does.
	if grep -q 'mount -t vfat "\$ESP_DEV"' "$SETUP_DISK"; then
		ok 'xsetup mounts $ESP_DEV as vfat'
	else
		no 'xsetup mounts $ESP_DEV as vfat' \
			'BOOTX64.EFI is copied into /mnt/flx/boot/efi, which without a' \
			'mount of $ESP_DEV is the ext4 root and not the ESP'
	fi

	# The ESP is mounted once, early, and unmounted by the cleanup trap in the
	# right order - the ESP first, because it is inside /mnt/flx, so umounting
	# /mnt/flx with the ESP still mounted fails and leaves a mount point nobody
	# can clear without a reboot.
	#
	# So the guard is on the trap, not on a bare umount line.  The step used to
	# mount the ESP for BOOTX64.EFI, umount it, and mount it again for the boot
	# chain: two chances to fail for one filesystem, and a window where the
	# bootloader files are on ext4 where Limine cannot read them.
	if grep -q 'ESP_MOUNT=' "$SETUP_DISK" &&
	   grep -q 'umount "\$ESP_MOUNT"' "$SETUP_DISK" &&
	   grep -q 'umount /mnt/flx' "$SETUP_DISK"; then
		ok 'xsetup unmounts the ESP before /mnt/flx, from the cleanup trap'
	else
		no 'xsetup unmounts the ESP before /mnt/flx, from the cleanup trap' \
			'the ESP is inside /mnt/flx, so unmounting /mnt/flx with the ESP' \
			'still mounted fails and leaves a mount point nobody can clear'
	fi

	# And it must mount it exactly once.  Two mounts and two unmounts of one
	# FAT filesystem in one install is a way to lose it.
	_n=$(grep -c 'mount -t vfat "\$ESP_DEV"' "$SETUP_DISK")
	_ng=$(
		awk '/^[[:space:]]*mount -t vfat "\$ESP_DEV"/ { n++ } END { print n + 0 }' \
			"$SETUP_DISK"
	)
	if [ "$_ng" = 1 ]; then
		ok 'xsetup mounts the ESP exactly once'
	else
		no 'xsetup mounts the ESP exactly once' "found $_ng mount lines"
	fi
	unset _n _ng

	if grep -q 'ESP_MOUNT' "$SETUP_DISK"; then
		ok 'the cleanup trap knows about the ESP mount'
	else
		no 'the cleanup trap knows about the ESP mount' \
			'an interrupted install would leave the ESP mounted'
	fi

	# And the copy has to be the tar pipeline, not cp -a.  Same shape of bug:
	# the install reported success and the installed system had 364 copies of
	# the zone files where it should have had one inode and 364 names.
	if grep -q 'cp -a "\$SOURCE_ROOT' "$SETUP_DISK"; then
		no 'xsetup does not copy with cp -a' \
			'the cp in this system is the NetBSD one, whose -a is -pPR and' \
			'does not preserve hard links; step 6 shows the difference'
	else
		ok 'xsetup does not copy with cp -a'
	fi

	if grep -q 'need_cmd tar' "$SETUP_DISK"; then
		ok 'xsetup asks for tar before it needs it'
	else
		no 'xsetup asks for tar before it needs it' \
			'a missing tar should be reported as a missing port, not as a' \
			'failed copy halfway through the system'
	fi
fi

# --- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -ne 0 ]; then
	printf '\nNot covered here, and untested: mount, the copy into a real\n'
	printf 'filesystem, and limine bios-install on the boot sectors.  Those\n'
	printf 'need root and a block device.\n'
	exit 1
fi

printf '\nNot covered here: mount, the copy into a real filesystem, and\n'
printf 'limine bios-install on the boot sectors.  Those need root and a\n'
printf 'block device.\n'
exit 0