#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# test-setup-disk.sh - exercise setup-disk.sh without a disk.
#
# The step is irreversible, and the parts most likely to be wrong -- which
# device node is which partition, what the geometry is, whether the tools
# exist -- are all decidable before anything is written.  So it runs with
# XSETUP_DRY_RUN=1 against a plain file standing in for a disk, and is checked
# for the decisions rather than for the destruction.
#
# What this does NOT cover, and does not pretend to: mkfs, the system copy,
# the bootloader and fstab.  Those need a real block device and root, and are
# untested here.
set -u

BASE=$(cd "$(dirname "$0")" && pwd)
STEP=$BASE/xsetup.d/setup-disk.sh
UI=$BASE/lib/ui.sh
ROOTFS=${ROOTFS:-$(cd "$BASE/.." && pwd)/src/rootfs}
FLXPART=${FLXPART:-$ROOTFS/sbin/flxpart}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok() {
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1)); printf '  ok   %s\n' "$1"
	else
		fail=$((fail + 1))
		printf '  FAIL %s\n        want [%s]\n        got  [%s]\n' "$1" "$3" "$2"
	fi
}

contains() {
	if printf '%s' "$2" | grep -qF -- "$3"; then
		pass=$((pass + 1)); printf '  ok   %s\n' "$1"
	else
		fail=$((fail + 1))
		printf '  FAIL %s: output has no [%s]\n' "$1" "$3"
		printf '%s\n' "$2" | sed 's/^/        /' | head -14
	fi
}

DISK=$TMP/disk.img
truncate -s 16G "$DISK"

# A stand-in for the medium the installer is running from.  It is not optional
# any more: the ESP is sized from the boot chain before the disk is partitioned,
# because a partition table cannot be resized afterwards and a chain that does
# not fit produces a disk with no system on it.
#
# The sizes are the real ones rather than empty files, because the point of the
# measurement is that it comes out right for a real payload.  A 218 MB initramfs
# is what FreeLinX actually ships; 1 MiB would let a broken measurement pass.
MEDIUM=$TMP/medium
mkdir -p "$MEDIUM/boot" "$MEDIUM/usr/share/limine"
truncate -s 12854400 "$MEDIUM/boot/bzImage"
truncate -s 218042373 "$MEDIUM/boot/initramfs.img.gz"
truncate -s 330888 "$MEDIUM/usr/share/limine/limine-bios.sys"
truncate -s 376832 "$MEDIUM/usr/share/limine/BOOTX64.EFI"

# run_step ANSWERS [MEDIUM] - feed ANSWERS to the step, in a scratch cwd, with
# the image's own tools on PATH, a dry run forced, and MEDIUM (or the default
# stub) standing in for the medium the installer is running from.
run_step() {
	( cd "$TMP" || exit 1
	  PATH=$ROOTFS/sbin:$ROOTFS/bin:$ROOTFS/usr/bin:$ROOTFS/usr/sbin:/usr/bin:/bin
	  export PATH
	  XSETUP_DRY_RUN=1
	  XSETUP_DISK_OVERRIDE=$DISK
	  XSETUP_MEDIUM=${2:-$MEDIUM}
	  FLXPART=$FLXPART
	  XSETUP_STATE_FILE=$TMP/mode
	  export XSETUP_DRY_RUN XSETUP_DISK_OVERRIDE XSETUP_MEDIUM FLXPART \
		XSETUP_STATE_FILE
	  printf '%s' "$1" | sh "$STEP" 2>&1
	)
}

nonzero() { tr -d '\0' <"$DISK" | wc -c | tr -d ' '; }

echo '== a dry run says so, and writes nothing =='
out=$(run_step '2
2
yes
')
contains 'says dry run' "$out" 'dry run'
ok 'the disk is untouched' "$(nonzero)" '0'

echo '== RAM mode touches nothing and records the mode =='
rm -f "$TMP/mode"
out=$(run_step '1
')
contains 'says running from RAM' "$out" 'running from RAM'
# Steps 12 and 13 read the mode to decide what to say.
ok 'the mode is recorded as none' "$(cat "$TMP/mode" 2>/dev/null)" 'none'
ok 'the disk is still untouched' "$(nonzero)" '0'

echo '== there is no data mode any more =='
# /init mounts no FREELINX_VAR filesystem, so a data disk was written and never
# used.  The menu offers RAM and install only.
out=$(run_step '3
')
case $out in
*'persistent storage'*) fail=$((fail + 1)); printf '  FAIL the menu still offers data mode\n' ;;
*) pass=$((pass + 1)); printf '  ok   the menu offers no data mode\n' ;;
esac
ok 'the disk is still untouched' "$(nonzero)" '0'

echo '== sys mode shows the four partitions /init expects =='
out=$(run_step '2
2
yes
')
contains 'names the EFI system partition' "$out" 'EFI system'
contains 'names the BIOS boot partition' "$out" 'BIOS boot'
contains 'names the system partition' "$out" '/usr /etc /var /root /bin /sbin /lib'
contains 'names the home partition' "$out" '/home'
contains 'the ESP is 1 GiB' "$out" '1024 MiB'
contains 'labels the system partition FLX_SYS' "$out" 'mkfs.ext4 -F -q -L FLX_SYS'
contains 'labels the home partition FLX_HOME' "$out" 'mkfs.ext4 -F -q -L FLX_HOME'
contains 'labels the ESP FLX_BOOT' "$out" 'mkfs.fat -F 32 -n FLX_BOOT'
ok 'the disk is still untouched' "$(nonzero)" '0'

echo '== the system partition is a share of the disk =='
# 16 GiB is under 20 GiB: 40%, at least 3 GiB.  16384 * 40 / 100 = 6553.
contains 'a 16 GiB disk gets a 6553 MiB system' "$out" '6553 MiB'
BIG=$TMP/big.img
truncate -s 40G "$BIG"
out=$( ( cd "$TMP" &&
	PATH=$ROOTFS/sbin:$ROOTFS/bin:$ROOTFS/usr/bin:$ROOTFS/usr/sbin:/usr/bin:/bin \
	XSETUP_DRY_RUN=1 XSETUP_DISK_OVERRIDE=$BIG XSETUP_STATE_FILE=$TMP/mode \
	sh "$STEP" 2>&1 <<EOF
2
2
yes
EOF
) )
# 40 GiB is 20 GiB or more: 30%, at least 6 GiB.  40960 * 30 / 100 = 12288.
contains 'a 40 GiB disk gets a 12288 MiB system' "$out" '12288 MiB'
rm -f "$BIG"

echo '== a disk under 8 GiB is refused =='
SMALL=$TMP/small.img
truncate -s 4G "$SMALL"
out=$( ( cd "$TMP" &&
	PATH=$ROOTFS/sbin:$ROOTFS/bin:$ROOTFS/usr/bin:$ROOTFS/usr/sbin:/usr/bin:/bin \
	XSETUP_DRY_RUN=1 XSETUP_DISK_OVERRIDE=$SMALL XSETUP_STATE_FILE=$TMP/mode \
	sh "$STEP" 2>&1 <<EOF
2
2
yes
EOF
) )
contains 'says it is too small' "$out" 'at least 8 GiB'
ok 'the small disk is untouched' "$(tr -d '\0' <"$SMALL" | wc -c | tr -d ' ')" '0'
rm -f "$SMALL"

echo '== declining the confirmation changes nothing =='
out=$(run_step '2
2
no
')
contains 'asks for the word yes' "$out" "type 'yes'"
ok 'the disk is still untouched' "$(nonzero)" '0'

echo '== the override is refused without a dry run =='
out=$( ( cd "$TMP" &&
	PATH=$ROOTFS/sbin:$ROOTFS/bin:$ROOTFS/usr/bin:$ROOTFS/usr/sbin:/usr/bin:/bin \
	XSETUP_DISK_OVERRIDE=$DISK XSETUP_STATE_FILE=$TMP/mode XSETUP_DRY_RUN=0 \
	sh -c ". $UI; need_root() { :; }; . $STEP" 2>&1 <<EOF
2
EOF
) )
contains 'refuses the override' "$out" 'only honoured with --dry-run'
ok 'the disk is still untouched' "$(nonzero)" '0'

echo '== need_cmd names the port that would supply the tool ==' 
out=$( printf '' | sh -c "PATH=/usr/bin:/bin; . $UI; need_cmd definitely_not_here 'the some/port' 2>&1" )
contains 'names the port' "$out" 'the some/port'
out=$( printf '' | sh -c "PATH=$ROOTFS/sbin:/usr/bin:/bin; . $UI; need_cmd flxpart 'the sysutils/flxpart port' 2>&1; echo rc=\$?" )
contains 'a present command passes' "$out" 'rc=0'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
cat <<'NOTE'

This suite is the conversation: the geometry, the confirmations, the guards, and
that a dry run touches nothing.  The commands a real run executes -- flxpart
writing a table, mkfs.fat, mkfs.ext4, blkid, the copy, the fstab -- are covered
by test-destructive.sh, which runs them against image files with the rootfs's own
binaries.  A real install -- mounting, the system image, limine bios-install,
booting the disk -- is test-xsetup-qemu.sh.
NOTE
exit $([ "$fail" -eq 0 ]; echo $?)
