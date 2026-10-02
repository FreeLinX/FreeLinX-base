#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-user - create a normal account to work in.
#
# A system you only ever use as root is a system where one typo is fatal, so
# this step exists to give the person installing it somewhere else to stand.
# The account goes in the wheel group, which is what sudo and doas look for.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi
need_root

if ! ask_yes 'Create a user account' y; then
	ok 'no user account created'
# # `return`, not `exit`.  A step is sourced by the dispatcher, not run as its own
# process, so `exit` here ends the whole installer rather than this step: the
# step printed its line, said everything was fine, and dropped the operator back
# at the shell prompt with steps 7 to 13 never run and nothing marked done.  It
# looked like the step failed, which is the opposite of what it said.

	return 0
fi

name=$(ask 'Username' '')
# Upper case is accepted and folded to lower case, rather than refused.
#
# The rule used to allow only a-z0-9_- and die on anything else, so typing
# Kanan ended the installer with
#
#     error: 'Kanan' is not a usable username: lower case letters, digits,
#            dash and underscore
#
# Lower case is the right thing to *store* - /etc/passwd lookups are case
# sensitive, so a mixed-case name is a trap for whoever comes next - but it is
# not a reason to throw away what somebody typed and end the install over.  The
# name is folded and the fold is said out loud, so nobody ends up wondering why
# the account they typed is not the one they got.
case $name in
''|*[!a-zA-Z0-9_-]*)
	die "'$name' is not a usable username: letters, digits, dash and underscore"
	;;
esac

folded=$(printf '%s' "$name" | tr 'A-Z' 'a-z')
if [ "$folded" != "$name" ]; then
	say "  $name -> $folded"
	name=$folded
fi

if awk -F: -v u="$name" '$1 == u { found = 1 } END { exit !found }' /etc/passwd; then
	die "the account $name already exists"
fi

need_cmd flxhash 'flxhash'

info "creating $name"

# The account is written here, the same way the desktop installer writes it:
# a group of its own, membership in wheel (doas) and the device groups, and
# the image's login shell (/etc/flx-shell; mksh on base).  The home is made
# in /home now and moved onto the FLX_HOME partition by setup-disk.
uid=1000
while grep -q "^[^:]*:[^:]*:$uid:" /etc/passwd; do uid=$((uid + 1)); done
gid=$uid
while grep -q "^[^:]*:[^:]*:$gid:" /etc/group; do gid=$((gid + 1)); done
ushell=$(cat /etc/flx-shell 2>/dev/null)
[ -x "${ushell:-/nonexistent}" ] || ushell=/bin/sh
printf '%s:x:%s:\n' "$name" "$gid" >>/etc/group
for g in wheel audio video input storage users; do
	grep -q "^$g:" /etc/group || continue
	awk -F: -v OFS=: -v g="$g" -v u="$name" \
		'$1 == g { $4 = ($4 == "" ? u : $4 "," u) } { print }' /etc/group >/etc/group.new
	cat /etc/group.new >/etc/group && rm -f /etc/group.new
done
printf '%s:x:%s:%s:%s:/home/%s:%s\n' "$name" "$uid" "$gid" "$name" "$name" "$ushell" >>/etc/passwd
mkdir -p "/home/$name"
chown "$uid:$gid" "/home/$name"
chmod 700 "/home/$name"

pw=$(ask_secret "Password for $name (nothing is shown)")
if [ -z "$pw" ]; then
	warn "$name will have an empty password, which allows anyone who reaches"
	warn 'this machine to log in as them. Set one later with passwd if unsure.'
	set_password "$name" ''
	warn "$name has no password. Anyone who reaches this machine can log"
	warn 'in as them. Set one with: passwd '"$name"
else
	set_password "$name" "$pw"
	pw=''
fi

if ask_yes 'Give this user sudo (as root)' y; then
	# doas is the other option, per the Alpine flow.  Checked first because
	# it is the one that can work on this image: sudo has no port here.
	if command -v doas >/dev/null 2>&1; then
		# The image's doas.conf already has rules (power, network tools);
		# writing the file anew would drop them.  Add the wheel rule only
		# if it is not there.
		grep -q '^permit persist :wheel$' /etc/doas.conf 2>/dev/null ||
			printf 'permit persist :wheel\n' >>/etc/doas.conf
		chmod 600 /etc/doas.conf
		ok "$name can use doas: in wheel, and /etc/doas.conf permits it"
	elif command -v sudo >/dev/null 2>&1; then
		# The group is the point: flxuseradd already put $name in wheel
		# with -G, and that is what sudo reads.  So there is no sudoers
		# line to write here, and writing one anyway would be a second
		# place the policy lives.
		if grep -q '^%wheel' /etc/sudoers 2>/dev/null; then
			ok "$name can use sudo: in wheel, and %wheel is enabled"
		elif grep -q '^#.*%wheel' /etc/sudoers 2>/dev/null; then
			warn '%wheel is present in /etc/sudoers but commented out,'
			warn "so $name is in the group and still cannot sudo."
			warn 'Uncomment the %wheel line, or run: visudo'
		else
			warn "/etc/sudoers has no %wheel rule at all, so $name is in"
			warn 'the group and still cannot sudo. Add:'
			warn '    %wheel ALL=(ALL:ALL) ALL'
			warn 'and check it with visudo before trusting it.'
		fi
	else
		# $name is in wheel either way, so installing a sudo port later
		# makes this work with no further configuration.
		warn "neither doas nor sudo is installed, so $name cannot escalate"
		warn 'privileges yet. They are in the wheel group, so installing'
		warn 'either one is all that is needed: the membership is already'
		warn 'in place and this step will find the rule or write it.'
	fi
fi

ok "user $name created"
