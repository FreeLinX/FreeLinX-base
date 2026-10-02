#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-apkcache - where downloaded package files are kept.
#
# xpkg keeps them in /var/cache/xpkg.  On an installed system /var is on the
# FLX_SYS partition, so the cache is on the disk.  On a system running from
# RAM it is in RAM and goes with the next reboot; `xpkg clean` empties it at
# any time.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi

MODE=none
[ -f /etc/xsetup-disk-mode ] && MODE=$(cat /etc/xsetup-disk-mode)

case $MODE in
sys)
	ok 'package cache: /var/cache/xpkg, on the FLX_SYS partition'
	;;
*)
	ok 'package cache: /var/cache/xpkg, in RAM (lost on reboot; xpkg clean empties it)'
	;;
esac
return 0
