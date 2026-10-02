#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# test-xsetup-qemu.sh - a whole install with xsetup, in a VM, and the
# installed system checked from the inside.
#
#   sh test-xsetup-qemu.sh [--uefi] [ISO]
#
# ISO must be built with SERIAL=1 (sh build-base.sh): the test talks to the
# system on its second serial port, where the live medium has a root shell and
# an installed system a login prompt.  Default: out/freelinx-base-serial.iso.
#
#   1. boot the ISO with an empty 12 GiB disk
#   2. run xsetup and answer every one of its 13 steps, as a person would:
#      keymap, hostname, interfaces (dhcp), root password, time zone, no proxy,
#      ntpd, the default repository, a user with doas, openssh, install to the
#      disk, then the last two steps
#   3. boot the disk with the medium removed
#   4. log in as the user and as root, and check what the steps set: hostname,
#      time zone, the user's groups and shell, sshd running, the UUID pins,
#      FLX_SYS bound, the framebuffer console
#   5. reboot, and check a file written in step 4 is still there
#
# Needs qemu-system-x86_64 (with KVM for speed) and, for --uefi, OVMF.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
UEFI=0
ISO=
for a do
	case $a in
	--uefi) UEFI=1 ;;
	*) ISO=$a ;;
	esac
done
ISO=${ISO:-$HERE/out/freelinx-base-serial.iso}
[ -f "$ISO" ] || { echo "no ISO at $ISO (build it with SERIAL=1)" >&2; exit 2; }
command -v qemu-system-x86_64 >/dev/null || { echo 'qemu-system-x86_64 not found' >&2; exit 2; }

# short: QEMU refuses unix socket paths of 108 bytes or more
W=$(mktemp -d /tmp/xsq.XXXXXX)
trap 'kill "$(cat "$W/pid" 2>/dev/null)" 2>/dev/null; rm -rf "$W"' EXIT
qemu-img create -f qcow2 "$W/disk.qcow2" 12G >/dev/null

FW=
if [ "$UEFI" = 1 ]; then
	OVMF=/usr/share/OVMF
	cp "$OVMF/OVMF_VARS_4M.fd" "$W/vars.fd"
	FW="-machine q35 -drive if=pflash,format=raw,readonly=on,file=$OVMF/OVMF_CODE_4M.fd -drive if=pflash,format=raw,file=$W/vars.fd"
fi
KVM=
[ -w /dev/kvm ] && KVM='-enable-kvm -cpu host'

vm() {
	rm -f "$W/sh.sock" "$W/console.log"
	# shellcheck disable=SC2086
	qemu-system-x86_64 $KVM -m 2048 -smp 2 $FW \
		-drive "file=$W/disk.qcow2,if=virtio,format=qcow2" "$@" \
		-vga std -display none -nic user,model=virtio-net-pci \
		-serial "file:$W/console.log" -serial "unix:$W/sh.sock,server,nowait" \
		-daemonize -pidfile "$W/pid" || exit 2
}
stop() { kill "$(cat "$W/pid")" 2>/dev/null; sleep 2; }

# serial PYTHON-ARGS... - talk to the guest's ttyS1 (see the helper below)
serial() { python3 "$W/serial.py" "$W/sh.sock" "$@"; }
cat >"$W/serial.py" <<'EOF'
import socket, sys, time
sock, mode = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.connect(sock); s.settimeout(0.5)
def rd(wait, until=None):
    b = b""; t = time.time()
    while time.time() - t < wait:
        try: b += s.recv(65536)
        except socket.timeout: pass
        if until and until in b: break
    return b.decode(errors="replace")
if mode == "run":            # run CMD on the live root shell, wait for it
    cmd, wait = sys.argv[3], float(sys.argv[4])
    s.sendall(b"\r"); rd(1)
    # the marker is split in the command, so the echo of what was typed
    # cannot be mistaken for the command's end
    s.sendall(cmd.encode() + b"; echo __EN''D__$?\r")
    out = rd(wait, b"__END__")
    out += rd(1)
    print(out)
elif mode == "ping":         # does the live root shell answer?
    s.sendall(b"echo pi''ng-ok\r")
    print(rd(3, b"ping-ok\r\n"))
elif mode == "login":        # log in as USER/PASS, run CMD, log out
    user, pw, cmd = sys.argv[3], sys.argv[4], sys.argv[5]
    s.sendall(b"\r"); rd(3, b"login:")
    s.sendall(user.encode() + b"\r"); rd(3, b"assword")
    s.sendall(pw.encode() + b"\r"); rd(4)
    s.sendall(cmd.encode() + b"; echo __EN''D__; exit\r")
    print(rd(20, b"__END__\r\n"))
EOF

pass=0; fail=0
check() {   # check NAME HAYSTACK NEEDLE
	if printf '%s' "$2" | grep -qF -- "$3"; then
		pass=$((pass + 1)); printf '  ok   %s\n' "$1"
	else
		fail=$((fail + 1)); printf '  FAIL %s (no [%s])\n' "$1" "$3"
	fi
}
wait_for() {   # wait_for PATTERN SECONDS - in the kernel console log
	n=0
	until grep -q "$1" "$W/console.log" 2>/dev/null; do
		n=$((n + 2)); [ "$n" -le "$2" ] || return 1; sleep 2
	done
}

echo "== boot the live medium ($([ "$UEFI" = 1 ] && echo UEFI || echo BIOS)) =="
vm -cdrom "$ISO" -boot d
# Wait for the shell itself, which answers once the system is up.  Not
# before Limine has handed over: on UEFI the firmware connects the serial
# ports to Limine's menu, and a byte sent during the countdown stops it and
# opens the entry editor ("e" of "echo").
sleep 40
n=0
until serial ping 2>/dev/null | grep -q 'ping-ok'; do
	n=$((n + 5)); [ "$n" -le 240 ] || { echo 'the medium did not boot'; exit 1; }
	sleep 5
done
sleep 10

echo '== xsetup, all 13 steps =='
# keymap us, hostname, eth0 dhcp, root password twice, region 6 (Asia) and
# its zone typed, no proxy, ntpd, the default repository, a user with a
# password and doas, openssh enabled, install (sys) to /dev/vda, yes.
ANS=$(printf '%s\n' 1 xbox 1 r00tpw r00tpw 6 Asia/Baku n 1 '' y alice al1cepw y 2 y 2 2 yes | base64 -w0)
out=$(serial run "echo $ANS | base64 -d > /root/ans; xsetup < /root/ans > /root/xsetup.log 2>&1" 1200)
check 'xsetup finished' "$out" '__END__0'
log=$(serial run "sed 's/\\x1b\\[[0-9;]*m//g' /root/xsetup.log | grep -E '^  ok|error' | tr -s ' '" 20)
for s in setup-keymap setup-hostname setup-interfaces setup-passwd setup-timezone \
	setup-proxy setup-ntp setup-apkrepos setup-user setup-sshd setup-disk \
	setup-lbu setup-apkcache; do
	check "$s done" "$log" "ok $s"
done
check 'the disk is installed' "$log" 'FreeLinX is installed on /dev/vda'
stop

echo '== boot the disk, medium removed =='
vm -boot c
wait_for 'FLX_SYS persistent system engaged' 180 && pass=$((pass + 1)) &&
	echo '  ok   FLX_SYS engaged at boot' ||
	{ fail=$((fail + 1)); echo '  FAIL FLX_SYS engaged at boot'; }
sleep 15
out=$(serial login alice al1cepw 'echo "who=$(id -un) sh=$0"; id; hostname; cat /etc/TZ; touch /home/alice/kept; ls /sys/firmware/efi >/dev/null 2>&1 && echo fw=UEFI || echo fw=BIOS')
check 'alice can log in' "$out" 'who=alice'
check "alice's shell is mksh" "$out" 'sh=-/bin/mksh'
check 'alice is in wheel' "$out" '(wheel)'
check 'the hostname is xbox' "$out" 'xbox'
check 'the time zone is Asia/Baku' "$out" 'Asia/Baku'
out=$(serial login root r00tpw 'echo "who=$(id -un)"; ls /var/service; tail -2 /var/log/sshd.log; cat /etc/flx-disk; mount | grep -c flx_sys; cat /sys/class/vtconsole/vtcon1/name; grep -c "^live:" /etc/passwd')
check 'root can log in' "$out" 'who=root'
check 'sshd is a service' "$out" 'sshd'
check 'sshd is listening' "$out" 'Server listening on'
check 'ntpd is a service' "$out" 'ntpd'
check 'the partitions are pinned' "$out" 'FLX_SYS_UUID='
check 'the console is a framebuffer' "$out" 'frame buffer device'
stop

echo '== reboot: what was written stays =='
vm -boot c
wait_for 'FLX_SYS persistent system engaged' 180
sleep 15
out=$(serial login alice al1cepw 'ls /home/alice/kept && echo kept-ok')
check "alice's file survived the reboot" "$out" 'kept-ok'
stop

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
