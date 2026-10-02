#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# setup-interfaces - decide how each network interface gets an address.
#
# Wired interfaces are dhcp or static or off.  A wireless interface needs an
# SSID and a passphrase, which are written to a wpa_supplicant config with
# 0600 because the file holds a password in the clear.
#
# Interfaces are found by looking at what the kernel has actually created,
# not by guessing names: a name that is not there is a name that will never
# be configured.

# ui.sh is sourced by the xsetup dispatcher, but each step sources it itself
# so that it can also be run, and tested, on its own.
if ! command -v choose >/dev/null 2>&1; then
	. "$(dirname "$0")/../lib/ui.sh"
fi
need_root
need_cmd ifconfig 'the net/ifconfig port'

# Where the answers go: the files the running system reads.
#
#   /etc/dhcpcd.conf                   dhcpcd (started by /init) takes a
#                                      static address from here, or leaves
#                                      an interface alone
#   /etc/wpa_supplicant/flxwifi.conf   the networks the flxwifi service
#                                      connects to at boot (0600: passwords)
DHCPCD_CONF=/etc/dhcpcd.conf
NETWORKS=/etc/wpa_supplicant/flxwifi.conf
BEGIN='# --- xsetup: begin ---'
END='# --- xsetup: end ---'


list_ifaces() {
	for d in /sys/class/net/*; do
		[ -e "$d" ] || continue
		n=${d##*/}
		# lo is not a question to ask anybody.
		[ "$n" = lo ] && continue
		# virtual interfaces (sit0, tunnels, bridges) have no device behind
		[ -e "$d/device" ] || continue
		printf '%s\n' "$n"
	done
}

ifaces=$(list_ifaces)

if [ -z "$ifaces" ]; then
	warn 'no network interface was found.'
	warn 'The kernel may lack a driver, or this really is a machine with no'
	warn 'network hardware. Nothing has been changed.'
# # `return`, not `exit`.  A step is sourced by the dispatcher, not run as its own
# process, so `exit` here ends the whole installer rather than this step: the
# step printed its line, said everything was fine, and dropped the operator back
# at the shell prompt with steps 7 to 13 never run and nothing marked done.  It
# looked like the step failed, which is the opposite of what it said.

	return 0
fi

info "interfaces found:"
printf '%s\n' "$ifaces" | sed 's/^/  /'

block=
for n in $ifaces; do
	if [ -d "/sys/class/net/$n/wireless" ]; then
		continue
	fi
	method=$(choose "How should $n be configured?" \
		dhcp 'automatic (DHCP)' \
		static 'a fixed address' \
		off 'leave it alone')
	case $method in
	dhcp)
		ok "$n: dhcp"
		;;
	static)
		addr=$(ask "  address for $n, for example 192.168.1.10/24" '')
		[ -n "$addr" ] || die "no address was given for $n"
		case $addr in
		*/*) ;;
		*) addr=$addr/24 ;;
		esac
		gw=$(ask '  default gateway (blank for none)' '')
		ns=$(ask '  nameserver (blank for none)' '')
		block="${block}interface $n
static ip_address=$addr
${gw:+static routers=$gw
}${ns:+static domain_name_servers=$ns
}"
		ok "$n: static $addr"
		;;
	off)
		block="${block}denyinterfaces $n
"
		ok "$n: not configured"
		;;
	esac
done

# Rewrite only our block of dhcpcd.conf, so whatever else is in it stays.
if [ -f "$DHCPCD_CONF" ]; then
	awk -v b="$BEGIN" -v e="$END" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' \
		"$DHCPCD_CONF" >"$DHCPCD_CONF.new"
else
	: >"$DHCPCD_CONF.new"
fi
if [ -n "$block" ]; then
	printf '%s\n%s%s\n' "$BEGIN" "$block" "$END" >>"$DHCPCD_CONF.new"
fi
mv -f "$DHCPCD_CONF.new" "$DHCPCD_CONF"

wifi=
for n in $ifaces; do
	[ -d "/sys/class/net/$n/wireless" ] && wifi=$n && break
done
if [ -n "$wifi" ] && ask_yes "Set up Wi-Fi on $wifi now" y; then
	ssid=$(ask 'Wi-Fi network name (SSID)' '')
	if [ -n "$ssid" ]; then
		psk=$(ask_secret 'Wi-Fi passphrase (blank for an open network; nothing is shown)')
		# The SSID as hex: SSIDs are arbitrary bytes (quotes, UTF-8, ...).
		hex=$(printf '%s' "$ssid" | od -An -tx1 | tr -d ' \n')
		if [ -n "$psk" ]; then
			[ "${#psk}" -ge 8 ] && [ "${#psk}" -le 63 ] ||
				die 'a WPA passphrase is 8 to 63 characters'
			case $psk in
			*'
'*) die 'the passphrase may not contain a newline' ;;
			esac
			net=$(printf ' ssid=%s\n psk="%s"\n sae_password="%s"\n key_mgmt=WPA-PSK WPA-PSK-SHA256 SAE\n ieee80211w=1\n' \
				"$hex" "$psk" "$psk")
		else
			net=$(printf ' ssid=%s\n key_mgmt=NONE\n' "$hex")
		fi
		psk=
		mkdir -p "${NETWORKS%/*}"
		# umask and the redirection in one subshell, or the file is 0644
		( umask 077; printf 'network={\n%s\n}\n' "$net" >"$NETWORKS" ) ||
			die "could not write $NETWORKS"
		chmod 600 "$NETWORKS"
		net=
		ok "Wi-Fi saved for $ssid: the flxwifi service connects at boot"
		if command -v flxwifi >/dev/null 2>&1; then
			sv restart /var/service/flxwifi >/dev/null 2>&1 || :
		fi
	fi
fi

ok "network settings written"
