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
truncate -s 4G "$DISK"

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

echo '== RAM mode touches nothing and writes no mode =='
rm -f "$TMP/mode"
out=$(run_step '1
')
contains 'says running from RAM' "$out" 'running from RAM'
# The mode file is written even for RAM, because steps 12 read it to decide
# whether they apply.  Asserting it was absent would have been asserting the
# bug that steps 12 would then hit.
ok 'the mode is recorded as none' "$(cat "$TMP/mode" 2>/dev/null)" 'none'
ok 'the disk is still untouched' "$(nonzero)" '0'

echo '== sys mode reports the real geometry, and partitions nothing =='
out=$(run_step '2
2
yes
')
contains 'says dry run' "$out" 'dry run'
contains 'names the EFI system partition' "$out" 'EFI system'
contains 'names the BIOS boot partition' "$out" 'BIOS boot'
contains 'resolves the root device' "$out" 'root'
ok 'the disk is still untouched' "$(nonzero)" '0'

echo '== the boot partition is sized for the boot chain =='
# The chain has to be readable by Limine's BIOS stage, which reads FAT and NTFS
# and no ext2/3/4, so the chain goes on the FAT ESP and the ESP has to be big
# enough for it.  The partition table is written before the copy, so this has to
# be right the first time: there is no resizing afterwards.
#
# 12854400 + 218042373 + 330888 + 4096 = 231231757 bytes, which is 220 MiB, so
# the floor of 256 applies and 252 is never reached.
out=$(run_step '2
2
yes
')
contains 'reports the chain size' "$out" 'boot chain  220 MiB'
contains 'sizes the ESP from it' "$out" 'ESP         256 MiB'

# And a chain too big for the floor gets an ESP sized to hold it.  400 MiB of
# initramfs needs 400 + 32, not 256: an ESP that is a hair too small fails at the
# last file with the disk half written.
BIGMED=$TMP/medium-big
mkdir -p "$BIGMED/boot"
truncate -s 12854400 "$BIGMED/boot/bzImage"
truncate -s 419430400 "$BIGMED/boot/initramfs.img.gz"
out=$(run_step '2
2
yes
' "$BIGMED")
contains 'reports the larger chain' "$out" 'boot chain  412 MiB'
contains 'grows the ESP past the floor' "$out" 'ESP         444 MiB'

# A missing medium is refused before the disk is touched, not after.  The step
# used to find the medium when it got to the boot section, which is after it has
# already partitioned and formatted the disk.
out=$(run_step '2
2
yes
' "$TMP/no-such-medium")
contains 'refuses without a medium' "$out" 'cannot find the medium'
contains 'says nothing was written' "$out" 'Nothing has been written'
ok 'the disk is still untouched' "$(nonzero)" '0'

echo '== declining the confirmation changes nothing =='
out=$(run_step '2
2
no
')
contains 'refuses' "$out" 'nothing was changed'
ok 'the disk is still untouched' "$(nonzero)" '0'

echo '== the override is refused without a dry run =='
# need_root comes first and this host is not root, so the override refusal is
# checked with a fake id(1) that reports 0.  That is the only way to reach the
# check here; the check itself is not conditional on being root.
out=$( cd "$TMP" && mkdir -p bin && printf '#!/bin/sh\n[ "$1" = -u ] && echo 0 || exec /usr/bin/id "$@"\n' > bin/id \
	&& chmod +x bin/id
	  PATH=$TMP/bin:$ROOTFS/sbin:$ROOTFS/bin:$ROOTFS/usr/bin:$ROOTFS/usr/sbin:/usr/bin:/bin \
	  XSETUP_DRY_RUN=0 XSETUP_DISK_OVERRIDE=$DISK \
	  XSETUP_STATE_FILE=$TMP/mode sh "$STEP" </dev/null 2>&1 )
contains 'refuses the override' "$out" 'only honoured with --dry-run'

echo '== data mode lays out a data partition and no boot chain =='
# A dry run, so the geometry is flxpart's real arithmetic with the writes
# skipped.  What is checked here is that this mode asks for the other layout, not
# that it asks well - flxpart's own suite checks what the layout contains.
out=$(run_step '3
2
yes
')
contains 'it runs a dry run' "$out" 'dry run'
contains 'it asks for a data layout' "$out" 'data filesystem'
contains 'no EFI system partition' \
	"$(printf '%s' "$out" | grep -ci 'EFI system' | tr -d ' ')" '0'
contains 'no BIOS boot partition' \
	"$(printf '%s' "$out" | grep -ci 'BIOS boot' | tr -d ' ')" '0'
ok 'the disk is still untouched' "$(nonzero)" '0'

echo '== data mode never reaches the sys install =='
# The bug this replaces: data mode ran the whole sys install - root partition,
# system copied, bootloader written - and then printed
#
#   ok  the system is installed.
#
# and exited 0, so a disk chosen for state ended up carrying a system and the
# installer said it had done what was asked.  These are the phrases the sys path
# is made of, and none of them may appear.
out=$(run_step '3
2
yes
')
for phrase in 'copying the system' 'system copied' 'making a FAT filesystem' \
	'installing the bootloader' 'bios-install' 'fstab written'; do
	ok "no sys step ran: $phrase" \
		"$(printf '%s' "$out" | grep -ci "$phrase" | tr -d ' ')" '0'
done

echo '== data mode labels the filesystem the way /init looks for it =='
# One string is the whole contract between the installer and the boot code.
# /init mounts a filesystem called FREELINX_VAR at /var; a different label means
# the disk is made, the install reports success, and /var is silently empty on
# every boot - so it is asserted here rather than left for a user to find out
# after a reboot.
out=$(run_step '3
2
yes
')
contains 'the label is FREELINX_VAR' "$out" 'FREELINX_VAR'

echo '== declining the erase stops data mode too =='
out=$(run_step '3
2
no
')
contains 'refuses' "$out" 'nothing was changed'
ok 'the disk is still untouched' "$(nonzero)" '0'
contains 'it did not partition' \
	"$(printf '%s' "$out" | grep -c 'data filesystem' | tr -d ' ')" '0'

echo '== the medium is found from where the step actually runs =='
# The step looks for the medium it booted from, because the kernel and the
# initramfs are on the medium and the boot partition has to be sized for them
# before the disk can be partitioned.
#
# It looked two levels up from $(dirname "$0"), which is wrong: a step is
# *sourced* by the dispatcher, so $0 is the dispatcher's path, and two levels up
# from /media/flx/installer/xsetup is /media - not /media/flx, where the medium
# is mounted.  Every lookup missed a mounted, readable medium and the step
# refused to install anything:
#
#     error: cannot find the medium this installer is running from.
#
# Reproduced here the way it is on the medium, and searched with the dispatcher
# standing in for $0, which is what the step actually saw.
MEDDIR=$TMP/fakemedium
mkdir -p "$MEDDIR/installer/xsetup.d" "$MEDDIR/boot"
cp "$BASE/xsetup" "$MEDDIR/installer/xsetup"
cp "$BASE/xsetup.d/setup-disk.sh" "$MEDDIR/installer/xsetup.d/setup-disk.sh"
: >"$MEDDIR/boot/initramfs.img.gz"

# The candidate list is lifted out of the step, not retyped here.
#
# A copy would pass forever while the step was wrong, which is the one thing a
# test like this exists to prevent: the search list is the fix, so the check has
# to be looking at the step's own list.
#
# Backslashes and newlines go because the list is written across two lines with a
# continuation; left in, the continuation's escaped space would glue /cdrom onto
# the end of the previous word and the list would be searched as one string.
_cands=$(awk '/for _c in/,/; do$/' "$BASE/xsetup.d/setup-disk.sh" |
	tr -d '\\\n\t' | sed 's/^.*for _c in //; s/; do$//; s/\$0/$1/g')

# The search runs from a file, with the dispatcher's path as $1.
#
# Two ways of getting $0 to mean the dispatcher both fail, and both fail
# quietly.  Inside single quotes a `sh -c '...'` body sees the *outer* shell's
# $0, so every candidate was somewhere else.  In a file it is the *finder's*
# $0, not the dispatcher's - a script's $0 is the script, and no amount of
# trailing arguments changes that.  Hence $1, which stands in for the dispatcher's
# path: that is what the step really sees, because the step is sourced.
printf '%s\n' \
	'#!/bin/sh' \
	'for _c in '"$_cands"'; do' \
	'	if [ -f "$_c/boot/initramfs.img.gz" ]; then' \
	'		(cd "$_c" && pwd); exit 0' \
	'	fi' \
	'done' \
	'exit 1' >"$MEDDIR/findmedium"

_found=$(cd "$MEDDIR/installer" && sh "$MEDDIR/findmedium" ./xsetup 2>/dev/null)
ok 'the medium is found with the dispatcher standing in for $0' \
	"$_found" "$MEDDIR"

# Asserted separately because it is the reason for the one above: if two levels
# up ever finds the medium, the layout has changed and the longer search is no
# longer what makes it work.  A fix that has quietly stopped being the reason
# still passes the test above it.
printf '%s\n' \
	'#!/bin/sh' \
	'for _c in "$(dirname "$1")/../.."; do' \
	'	if [ -f "$_c/boot/initramfs.img.gz" ]; then printf yes; exit 0; fi' \
	'done' \
	'printf no' >"$MEDDIR/findold"
_old=$(cd "$MEDDIR/installer" && sh "$MEDDIR/findold" ./xsetup 2>/dev/null)
ok 'two levels up alone would miss it' "$_old" 'no'

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
binaries.  What neither suite can do is mount, so the copy crossing into a real
filesystem and limine bios-install on the boot sectors are still untested: those
need root and a block device.
NOTE
exit $([ "$fail" -eq 0 ]; echo $?)
