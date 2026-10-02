#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# ui.sh - prompts, menus and messages for xsetup.
#
# Sourced by xsetup and by every step in xsetup.d.  Nothing here runs a
# command or touches the disk; it is the only place that talks to the user, so
# every step looks and behaves the same way.

C_RED=''
C_GREEN=''
C_CYAN=''
C_YELLOW=''
C_BOLD=''
C_OFF=''

# No colour.
#
# Not "colour only on a terminal" - no colour at all, and the variables are
# empty rather than unset so every caller still works unchanged.  An installer
# prints thirteen step banners, a menu per question and a line of feedback per
# answer; in red, green, cyan and yellow that is a great deal of colour for
# something you read top to bottom while making decisions.  White is easier to
# follow for that, and it is also the only thing that survives being piped to a
# file or read over serial without a tty - which is how the installer is run by
# its own test suite, and how anyone with a serial console reads it.
#
# The step list, the menus and the ok/warn/error lines are still distinguished by
# their wording and position, which is how they were before colour existed.
C_RED=''
C_GREEN=''
C_CYAN=''
C_YELLOW=''
C_BOLD=''
C_OFF=''

# say MESSAGE... - ordinary progress output.
say() {
	printf '%s\n' "$*"
}

# info MESSAGE... - a labelled line, for "here is what I am about to do".
info() {
	printf '%s==>%s %s\n' "$C_CYAN$C_BOLD" "$C_OFF" "$*"
}

# ok MESSAGE... - something finished successfully.
ok() {
	printf '%s  ok%s %s\n' "$C_GREEN" "$C_OFF" "$*"
}

# warn MESSAGE... - non-fatal trouble the user should know about.
warn() {
	printf '%swarning:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2
}

# die MESSAGE... - give up.  Exits, so a step never carries on past this.
die() {
	printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
	exit 1
}

# ask PROMPT [DEFAULT] - read one line.  An empty answer takes the default.
ask() {
	_prompt=$1
	_default=${2:-}
	_reply=
	if [ -n "$_default" ]; then
		printf '%s' "$_prompt [$_default]: " >&2
	else
		printf '%s' "$_prompt: " >&2
	fi
	# read returns non-zero at EOF, which is not an error to retry: a closed
	# stdin means the user is gone, and looping here would spin forever.
	if ! IFS= read -r _reply; then
		printf '\n' >&2
		die 'input ended before anything was entered'
	fi
	[ -n "$_reply" ] || _reply=$_default
	printf '%s' "$_reply"
}

# ask_yes PROMPT [DEFAULT] - a yes/no question.  DEFAULT is y or n.
# ask_secret PROMPT - like ask, but what is typed is not shown.  For
# passwords: ask echoed them to the screen and the scrollback.
ask_secret() {
	printf '%s: ' "$1" >&2
	# Only echo is turned off, so only echo is turned back on: restoring a
	# saved `stty -g` state fails on Linux with this stty, and under set -e
	# that failure ended the installer with the terminal left silent.
	_secret_off=0
	if [ -t 0 ] && stty -echo 2>/dev/null; then
		_secret_off=1
	elif [ -t 0 ]; then
		printf '(stty is missing: what you type is shown) ' >&2
	fi
	if ! IFS= read -r _reply; then
		[ "$_secret_off" = 1 ] && { stty echo 2>/dev/null || :; }
		printf '\n' >&2
		die 'input ended before anything was entered'
	fi
	[ "$_secret_off" = 1 ] && { stty echo 2>/dev/null || :; }
	printf '\n' >&2
	printf '%s' "$_reply"
	_reply=
}

# set_password USER PASSWORD - store PASSWORD's SHA-512 crypt hash for USER
# in /etc/shadow (an empty PASSWORD leaves the account without one).  The
# password reaches flxhash on stdin, never on a command line.
set_password() {
	if [ -n "$2" ]; then
		_h=$(printf '%s\n' "$2" | flxhash - 2>/dev/null) || _h=
		case $_h in
		'$6$'*) ;;
		*) die "flxhash could not hash the password for $1" ;;
		esac
	else
		_h=
	fi
	_day=$(( $(date +%s) / 86400 ))
	if grep -q "^$1:" /etc/shadow; then
		awk -F: -v OFS=: -v u="$1" -v h="$_h" -v d="$_day" \
			'$1 == u { $2 = h; $3 = d } { print }' /etc/shadow >/etc/shadow.new
	else
		{ cat /etc/shadow; printf '%s:%s:%s:0:99999:7:::\n' "$1" "$_h" "$_day"; } >/etc/shadow.new
	fi
	cat /etc/shadow.new >/etc/shadow && rm -f /etc/shadow.new
	chmod 600 /etc/shadow
	_h=
}

ask_yes() {
	_prompt=$1
	_default=${2:-y}
	case $_default in
	y|Y) _hint='[Y/n]' ;;
	*)   _hint='[y/N]' ;;
	esac
	while :; do
		# See choose: ask runs in a substitution, so EOF has to be caught
		# by testing the status rather than trusting ask to stop us.
		if ! _reply=$(ask "$_prompt [$_hint]" ''); then
			return 1
		fi
		case $_reply in
		'')
			# An empty answer takes the default the caller asked for, which
			# is the whole reason the default is printed in the prompt.
			#
			# It used to be grouped with yes whatever the default was, so
			# every prompt reading [y/N] answered yes when Enter was pressed,
			# and the operator was then asked a question they had declined:
			#
			#     Use an HTTP proxy for downloads [[y/N]]:
			#     Proxy host:
			#     error: no proxy host given
			#
			# Five of the eight ask_yes calls in this tree pass n, so that was
			# the answer to five of them - and one of them then died on the
			# question it had been told not to answer.
			case $_default in
			y|Y) return 0 ;;
			*)   return 1 ;;
			esac
			;;
		y|Y|yes|Yes|YES) return 0 ;;
		n|N|no|No|NO)     return 1 ;;
		esac
		warn "answer y or n"
	done
}

# choose PROMPT ITEM... - numbered menu, returns the chosen item's argument.
#
# The last argument is the value returned; everything before it is what the
# user sees.  This is what makes a menu a menu: the caller never has to map a
# number back to a value, and a menu can never be accidentally muted, because
# there is no code path here that hides the list.
# choose PROMPT VALUE LABEL [VALUE LABEL]... - numbered menu, returns VALUE.
#
# Each option is a value and the label that describes it, as a pair.  The
# pairs are the point: with a single value followed by a list of labels, the
# value has to be repeated as a label or it shows up in the menu as an option,
# and every call site got that wrong the same way -- the disk menu offered
# "1) run from RAM  2) sys  3) install onto a disk  4) data".  Pairs also let a
# value differ from what is displayed, which is what a caller wants when the
# value is a word like "none" and the label is a sentence.
#
# Nothing here can mute the list: the labels are the only way to answer, so a
# caller that wants a menu gets a menu.
choose() {
	_prompt=$1
	shift
	_nargs=$#

	if [ $((_nargs % 2)) -ne 0 ]; then
		printf '%serror:%s choose: "%s" was given an odd number of arguments;\n' \
			"$C_RED" "$C_OFF" "$_prompt" >&2
		printf '%s     each option needs a value and a label%s\n' \
			"$C_RED" "$C_OFF" >&2
		return 1
	fi

	printf '%s%s%s\n' "$C_BOLD" "$_prompt" "$C_OFF" >&2

	_nopts=$((_nargs / 2))

	# Print the labels in a subshell, because the walk shifts the positional
	# parameters and the answer has to come out of the same ones afterwards.
	# Shifting in this shell would leave nothing left to return: the menu
	# printed correctly and every answer came back empty.  Indirect
	# expansion ${!_i} is the obvious alternative and is not POSIX -- bash
	# and musl ash both have it, but a POSIX sh need not, and this is the one
	# function every step goes through.
	# Across the screen rather than down it.
	#
	# The region list is 60-odd entries and the city list runs to several
	# hundred; one per line is a wall of text you scroll to find a country in.
	# Laid out in columns the same list is a screen or two, and the number
	# beside each name is unchanged.
	#
	# Width from COLUMNS when it is set, else 80.  tty(1) is not asked: it is
	# another process per menu and this system has no working /dev/stdin for
	# programs that open it.  A wrong COLUMNS gives a wide or a cramped menu,
	# which is cosmetic; every number is still printed and still means what it
	# said.
	_cols=${COLUMNS:-80}
	[ "$_cols" -gt 20 ] 2>/dev/null || _cols=80

	(
		# Columns are packed by a fixed cell, not by the width of the widest
		# label.  Measuring it was here, and it did nothing: it read ${#_i},
		# the length of the loop counter, so the width came out as 1 and no
		# label was ever padded.  Measuring the label properly is worse than
		# leaving it out - every column then becomes as wide as the longest
		# name in the list, and the region list's longest name is long enough
		# to halve how many countries fit on a screen.  Ragged columns cost
		# some neatness; aligned ones cost rows, and the rows are what people
		# scroll through looking for Turkey.
		#
		# Per column: the number, its bracket, two spaces, the label, and a
		# gap of two.  Numbers wider than one digit overflow their column and
		# push that one row along, which is why the keymap list is checked for
		# being two characters wide rather than for being twenty-four short.
		_cell=12
		_perrow=$((_cols / _cell))
		[ "$_perrow" -lt 1 ] && _perrow=1

		_i=1
		_col=0
		while [ "$_i" -le "$_nargs" ]; do
			_label=$2
			shift 2
			if [ "$_col" -eq 0 ]; then
				printf '  ' >&2
			fi
			printf '%s) %s' "$(((_i + 1) / 2))" "$_label" >&2
			_col=$((_col + 1))
			if [ "$_col" -ge "$_perrow" ]; then
				printf '\n' >&2
				_col=0
			else
				printf '  ' >&2
			fi
			_i=$((_i + 2))
		done
		# `if`, not `&&`, and this is not a style preference.
		#
		# The trailing newline when the last row is short.  Written as
		#
		#     [ "$_col" -ne 0 ] && printf '\n' >&2
		#
		# it is the last command of this subshell, so when the options fill
		# the last row exactly _col is 0 and it returns 1.  xsetup runs under
		# `set -e`, a command substitution is a subshell, and errexit in a
		# subshell kills the substitution the moment a command fails.  The
		# menu printed, the prompt never did, choose returned nothing and the
		# installer exited:
		#
		#     [1/13] setup-keymap
		#     Keyboard layout
		#       1) us  2) gb ... 23) gr  24) no change
		#     root@freelinx:~#
		#
		# Only when the count is a multiple of the row width, which is why it
		# looked like nothing to do with menus: five options work, six do not,
		# twenty-one works and twenty-four does not.  The old keymap menu had
		# five entries and the new one has twenty-four.
		#
		# An `if` with no branch taken returns 0 whatever the condition was.
		if [ "$_col" -ne 0 ]; then
			printf '\n' >&2
		fi
	)

	while :; do
		# ask dies on EOF, but it runs inside a command substitution, so its
		# exit only ends the substitution.  Testing the status here is the
		# only way the loop learns that input has ended; without this it
		# re-prompts forever.
		if ! _reply=$(ask 'choice' ''); then
			exit 1
		fi
		case $_reply in
		'')
			warn 'nothing chosen'
			continue
			;;
		*[!0-9]*)
			warn "'$_reply' is not a number"
			continue
			;;
		esac
		if [ "$_reply" -lt 1 ] || [ "$_reply" -gt "$_nopts" ]; then
			warn "choose 1 to $_nopts"
			continue
		fi
		# Walk to the chosen pair and print its value.
		_i=1
		while [ "$_i" -lt "$_reply" ]; do
			shift 2
			_i=$((_i + 1))
		done
		printf '%s' "$1"
		return 0
	done
}

# confirm PROMPT - ask for a word and insist it matches, for anything that
# destroys a disk.
confirm() {
	_prompt=$1
	while :; do
		if ! _reply=$(ask "$_prompt, type 'yes' to continue" ''); then
			return 1
		fi
		[ "$_reply" = yes ] && return 0
		warn "type 'yes' exactly, or nothing happens"
	done
}

# need_cmd NAME [HINT] - fail unless NAME can be run.
#
# A step that quietly does half its job is worse than one that stops, so a
# step checks its tooling up front and says which port supplies what is
# missing.  HINT names the port, because "command not found" is not something
# the person holding the keyboard can act on.
need_cmd() {
	command -v "$1" >/dev/null 2>&1 && return 0
	if [ -n "${2:-}" ]; then
		# The second argument is a complete phrase naming the port, not a
		# bare port name: wrapping it here gave "It comes from the the
		# sysutils/flxpart port port".
		die "$1 is not installed, so this step cannot do its job.
     It comes from $2."
	fi
	die "$1 is not installed, so this step cannot do its job."
}

# need_root - fail unless running as root.
need_root() {
	[ "$(id -u)" = 0 ] || die 'this step has to be root: it writes to /etc'
}

# step_start N NAME - banner at the top of each of the twelve steps.
step_start() {
	printf '\n%s%s[%s/%s] %s%s\n' "$C_BOLD" "$C_CYAN" "$1" "$2" "$3" "$C_OFF"
}

# done_message - printed by xsetup when every step has been run.
done_message() {
	printf '\n%s%sSetup complete.%s\n' "$C_BOLD" "$C_GREEN" "$C_OFF"
	if [ "$(cat /etc/xsetup-disk-mode 2>/dev/null)" = sys ]; then
		printf 'Reboot, remove the medium, and boot from the disk.\n'
	else
		printf 'The system runs from RAM: nothing is kept after a reboot.\n'
	fi
}
