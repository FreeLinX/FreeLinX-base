#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-ntp - choose how the clock is kept.
#
# FreeLinX uses runit, not OpenRC, so enabling a service means putting its
# directory under /var/service.  /etc/svc is where the service definitions
# live and /var/service is what runit actually runs; a service is enabled by
# a symlink from one to the other.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi
need_root

choice=$(choose 'How should the clock be kept?' \
	ntpd 'ntpd, from the FreeLinX base image' \
	none 'nothing, set the clock by hand')

# Drop any service the previous answer enabled, so the choice is not additive
# and re-running the step does what it says.
if [ -L /var/service/ntpd ]; then
	rm -f /var/service/ntpd
fi

case $choice in
ntpd)
	need_cmd ntpd 'the net/ntpd port'

	if [ -d /etc/svc/ntpd ]; then
		ln -sfn /etc/svc/ntpd /var/service/ntpd
		ok 'ntpd enabled'
	elif [ -d /var/service/ntpd ]; then
		ok 'ntpd already in /var/service'
	else
		# Say where it went rather than claiming success.
		die 'there is no /etc/svc/ntpd to enable.
     The service definition has to be staged by the image build first.'
	fi

	# The clock is usually wrong on first boot, which makes every
	# certificate check fail until it is roughly right.  Ask the network
	# directly, once, to get over that.
	info 'ntpd sets the clock within a minute or two of starting'
	;;
none)
	warn 'the clock will not be kept in sync.'
	warn 'Package downloads can fail on certificate checks until it is right.'
	ok 'no time daemon enabled'
	;;
esac
