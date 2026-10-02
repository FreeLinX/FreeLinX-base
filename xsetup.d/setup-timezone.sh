#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-timezone - set the local time zone.
#
# A zone is a file under /usr/share/zoneinfo, and the system is told which
# one by /etc/localtime being a copy of it.  A copy rather than a symlink
# because a symlink breaks the moment the zone database is upgraded or the
# disk is mounted somewhere else.  /etc/timezone names the zone in text, for
# the things that cannot follow a link.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi
need_root

ZONEINFO=/usr/share/zoneinfo

if [ ! -d "$ZONEINFO" ]; then
	die "there is no $ZONEINFO, so no zone can be selected.
     The zone database comes from the base/tzdata port."
fi

# The zones are nested Region/City, and some are deeper still
# (America/Argentina/Buenos_Aires), so the whole tree is flattened once and
# the menu is driven off that: region first, then the city within it, which
# is how anyone actually looks for a zone.  A single flat list of 600 zones
# would be unusable.
# Sorted from a file, not from a pipe.
#
# This system's sort does not read file descriptor 0.  It opens /dev/stdin, and
# on FreeLinX /dev/stdin is a symlink to /proc/self/fd/0, which cannot be
# opened here:
#
#     $ sh -c 'sort </dev/null'
#     sort: /dev/stdin: No such file or directory
#
# Note the explicit redirect: the input was /dev/null, a real device, and it
# still failed.  Nothing about the pipe is the problem.  `ls /proc/self/fd/`
# answers "permission denied", so the path /dev/stdin points at does not resolve
# for any process, and every sort on this system dies on any input at all.
#
# So the list is written to a scratch file and sort is given that file to open
# by name.  That path does not go through /dev/stdin and works.  A pipe would be
# the shorter spelling and cannot be used.
#
# The scratch file is created once and reused by both sorts, and removed by the
# trap at the bottom of this step.
ZONES_TMP=${ZONES_TMP:-/tmp/xsetup-zones.$$}
trap 'rm -f "$ZONES_TMP" "$ZONES_TMP.regions"' EXIT INT TERM

# menu_pairs LIST - "value label" arguments for choose, one pair per line on
# stdout, unquoted, for word splitting by the caller.
#
# Each name is its own value and its own label: choose displays the label and
# returns the value, and here they are the same string.
menu_pairs() {
	# "$@", not "$1".  The caller passes the whole list as separate words and
	# then lets choose's own word splitting take it apart again; reading only the
	# first argument gives one region, and the menu offers a single choice no
	# matter how many regions exist.
	for _r in "$@"; do
		printf '%s %s\n' "$_r" "$_r"
	done
}

zones_list() {
	find "$ZONEINFO" -type f 2>/dev/null |
		sed "s|^$ZONEINFO/||" |
		grep -vE '(^|/)(posix|right)(/|$)' |
		grep -v '\.tab$' |
		grep -vE '^(\.|localtime|posixrules|leapseconds|Factory)$' \
		>"$ZONES_TMP"
	sort "$ZONES_TMP" -o "$ZONES_TMP" || die 'cannot sort the zone list'
	cat "$ZONES_TMP"
}

zones=$(zones_list)

if [ -z "$zones" ]; then
	die "$ZONEINFO is there but empty."
fi

zone=
while :; do
	# Same reason as zones_list: sort is given a file to open by name, never a
	# pipe, because it cannot read a pipe on this system.
	printf '%s\n' "$zones" | cut -d/ -f1 >"$ZONES_TMP.regions"
	sort -u "$ZONES_TMP.regions" -o "$ZONES_TMP.regions" ||
		die 'cannot sort the region list'
	regions=$(cat "$ZONES_TMP.regions")
	# One value and one label per region, in that order, which is what choose
	# pairs up.  This produced one word per region instead - a region name
	# wrapped in quotes and nothing else - so choose paired each region with the
	# *next* one as its label and the last one with nothing:
	#
	#     26) "ROC"
	#     27) "Singapore"
	#
	# The quotes in the menu are the labels the caller passed, and the value a
	# choice returned was the following region's name.  Picking anything returned
	# a name that was not what was asked for, and the step died trying to use it.
	#
	# Region names have no spaces in them, so plain word splitting is safe here
	# and the quoting is unnecessary as well as wrong.
	# shellcheck disable=SC2086
	# "none" needs a label as well as a value, or the argument count is odd and
	# choose refuses the whole menu:
	#
	#     error: choose: "Region" was given an odd number of arguments
	#
	# Each entry is one value and one label.  A bare `none` is one word, so it is
	# half an entry.
	# shellcheck disable=SC2086
	region=$(choose 'Region' none 'leave it alone' $(menu_pairs $regions))
	[ "$region" = none ] && die 'no time zone was chosen'
	# A region with no slash in it is itself a zone.
	#
	# UCT, Zulu, Universal, ROC, ROK, Turkey, Singapore and a dozen others are
	# single zones stored as themselves, not as themselves with a city under
	# them: the database has UCT, not UCT/Anything.  So the city grep below finds
	# nothing, the city menu is built from an empty list, and the only entry is
	# the escape - a menu of one that cannot be answered with the zone the
	# operator selected.  UTC was special-cased here and worked; every other
	# single-zone region did not, and choosing one ended the installer:
	#
	#     55) UCT
	#     Time zone under UCT:
	#     error: input ended before anything was entered
	#
	# which is what choosing 55 does.
	#
	# Match the region on the trailing slash *or* the end of the name, so both
	# shapes are found and the city menu is only built when there really are
	# cities.
	if printf '%s\n' "$zones" | grep -qx "$region"; then
		zone=$region
		break
	fi

	cities=$(printf '%s\n' "$zones" | grep "^$region/")
	if [ "$(printf '%s\n' "$cities" | wc -l | tr -d ' ')" -le 40 ]; then
		# shellcheck disable=SC2086
		zone=$(choose "City in $region" none 'leave it alone' \
			$(menu_pairs $cities))
		[ "$zone" = none ] && continue
		break
	fi
	printf '  %s has too many zones for a list; type the full name.\n' "$region"
	zone=$(ask "Time zone under $region" '')
	case $zone in
	"$region"/*) break ;;
	*) warn "that is not a zone under $region" ;;
	esac
done

[ -n "$zone" ] || die 'no time zone was chosen'

src=$ZONEINFO/$zone
[ -f "$src" ] || die "$src is not a file, so it cannot be copied"

info "setting the time zone to $zone"
cp "$src" /etc/localtime
printf '%s\n' "$zone" >/etc/timezone
# /etc/TZ is what FreeLinX reads: /etc/profile exports TZ from it
printf '%s\n' "$zone" >/etc/TZ
export TZ="$zone"

# /etc/localtime is a copy, so its mode should say so plainly.
chmod 644 /etc/localtime

ok "time zone is $zone"
