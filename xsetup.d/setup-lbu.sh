#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-lbu - where changes to the system are kept.
#
# On an installed system (setup-disk: sys) /usr /etc /var /root /bin /sbin
# and /lib are on the FLX_SYS partition, so every change is kept and there is
# nothing to choose.  A system running from RAM (setup-disk: none) keeps
# nothing: FreeLinX has no overlay that saves RAM changes to another disk, and
# this step says so instead of asking for a disk it would not use.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi

MODE=none
[ -f /etc/xsetup-disk-mode ] && MODE=$(cat /etc/xsetup-disk-mode)

case $MODE in
sys)
	ok 'the system is on a disk: changes are kept on its FLX_SYS partition'
	;;
*)
	warn 'the system runs from RAM: changes are lost when it reboots.'
	warn 'To keep them, install it: xsetup --reset setup-disk, then xsetup.'
	ok 'nothing to keep'
	;;
esac
# `return`, not `exit`: a step is sourced by the dispatcher, and exit would
# end the whole installer.
return 0
