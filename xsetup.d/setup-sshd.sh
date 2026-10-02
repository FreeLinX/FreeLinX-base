#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-sshd - optionally run an SSH daemon.
#
# Enabling remote login is a decision with consequences, so the step asks
# plainly and says what it is about to do.  Host keys are generated at setup
# time rather than shipped, because a host key baked into an image is the
# same key on every machine ever installed from it.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi
need_root

choice=$(choose 'SSH daemon' \
	none 'none, do not allow remote login' \
	openssh 'openssh')

case $choice in
none)
	# If it was enabled before, take it back out again.
	[ -L /var/service/sshd ] && rm -f /var/service/sshd
	ok 'no SSH daemon enabled'
# # `return`, not `exit`.  A step is sourced by the dispatcher, not run as its own
# process, so `exit` here ends the whole installer rather than this step: the
# step printed its line, said everything was fine, and dropped the operator back
# at the shell prompt with steps 7 to 13 never run and nothing marked done.  It
# looked like the step failed, which is the opposite of what it said.

	return 0
	;;
esac

warn "enabling $choice means anyone who can reach this machine and knows an"
warn 'account may log in over the network. Make sure the root password set'
warn 'in step 4 is not the only thing standing between them and a shell.'
printf '\n'
ask_yes 'Enable it anyway' y || { ok 'left disabled'; return 0; }

need_cmd ssh-keygen 'the net/openssh port'

mkdir -p /etc/ssh
chmod 700 /etc/ssh

# 2048 bits of ed25519 is the modern default; a host key is generated once per
# machine, so the type costs nothing.
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
	info 'generating host keys'
	ssh-keygen -q -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N '' ||
		die 'ssh-keygen could not generate a host key'
	ssh-keygen -q -t rsa -b 3072 -f /etc/ssh/ssh_host_rsa_key -N '' || :
	chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || :
	ok 'host keys generated'
fi

if [ ! -d "/etc/svc/$choice" ]; then
	die "there is no /etc/svc/$choice to enable.
     The service definition has to be staged by the image build first."
fi
ln -sfn "/etc/svc/$choice" /var/service/sshd
ok "$choice enabled in /var/service"
