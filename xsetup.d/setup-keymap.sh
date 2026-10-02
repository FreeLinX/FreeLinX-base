#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-keymap - pick the keyboard layout.
#
# Recorded in /etc/conf.d/loadkmap.conf, and not applied: see below.
#
# It does not, and cannot, re-lay-out the running text console.  KDSETKEYMAP,
# the ioctl that used to allow it, was removed from Linux along with
# struct kbentry and the rest of the old kd.h console API; the console now
# carries one keymap compiled into the kernel, and there is no interface a
# program on a running system can use to change it.  NetBSD's kbdcomp and
# loadkeys are a pair for an interface that no longer exists here.
#
# So the answer is recorded and not applied, and this says so plainly.  A step
# that appeared to change the console and did not would leave somebody typing
# a German layout on a US console with no way to tell why.
#
# This step used to record an XKB symbol-set name and then check that the file
# was there, warning when it was not.  base has no X server and no X client and
# /usr/share/X11/xkb is not in the image, so on every run it warned:
#
#     ok recorded us in /etc/conf.d/loadkmap.conf
#     warning: there is no /usr/share/X11/xkb/symbols/us, so a graphical
#     warning: session will fall back to its default layout.
#
# A check for a file that is never present is not a check.  It is a warning
# about the image, printed on every install as though the operator had done
# something wrong.
# typing a German layout on a US console with no way to tell why.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi
need_root

mkdir -p /etc/conf.d

# "uk" is a real keyboard but not a real layout name here -- it is "gb" --
# so offering it would record a name nothing on this system knows.
# that nothing could load.
# The console itself cannot be relaid out, so this only records the choice - see
# the header.  The list is still worth having: it is what /etc/conf.d/loadkmap.conf
# is for, and a system installed on one keyboard and used on another is a real
# situation.
#
# Wider than it was, and for the usual reason: four layouts is a list that looks
# deliberate and is actually an arbitrary stopping point.  These are the layouts
# a machine is most likely to be typed on, and every one of them is a name a
# later system can do something with.
# The label is the whole menu: choose prints the label and nothing else.  These
# were "tr   Turkish" and the country names are gone - twenty-four of them is a
# paragraph of English to read in order to pick two letters, and the two letters
# are what loadkeys takes and what /etc/conf.d/loadkmap.conf ends up holding.
# Hence each code is written twice, once as the value the step stores and once as
# the label the operator sees.  "leave it as it is" is not a code and stays
# spelled out.
keymap=$(choose 'Keyboard layout' \
	us us \
	gb gb \
	ca ca \
	ie ie \
	de de \
	at at \
	ch ch \
	es es \
	it it \
	pt pt \
	nl nl \
	be be \
	se se \
	no no \
	dk dk \
	fi fi \
	pl pl \
	cz cz \
	hu hu \
	ro ro \
	tr tr \
	ru ru \
	gr gr \
	none 'no change')

if [ "$keymap" = none ]; then
	rm -f /etc/conf.d/loadkmap.conf
	ok 'layout left alone'
# # `return`, not `exit`.  A step is sourced by the dispatcher, not run as its own
# process, so `exit` here ends the whole installer rather than this step: the
# step printed its line, said everything was fine, and dropped the operator back
# at the shell prompt with steps 7 to 13 never run and nothing marked done.  It
# looked like the step failed, which is the opposite of what it said.

	return 0
fi

{
	printf '# Written by xsetup.\n'
	printf 'KEYMAP=%s\n' "$keymap"
} >/etc/conf.d/loadkmap.conf
# the layout a desktop installed later starts X with
printf '%s\n' "$keymap" >/etc/flx-kbd
ok "recorded $keymap in /etc/conf.d/loadkmap.conf"

say ''
say '  The text console keeps the layout it booted with: Linux removed the'
say '  ioctl that used to let a program change it, so there is no way for a'
say '  running system to relayout the console. The choice is recorded for a'
say '  later system to use.'
