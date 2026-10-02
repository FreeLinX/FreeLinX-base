#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# mkrootfs.sh - make the base rootfs: the desktop's system, without the desktop.
#
#   sh scripts/mkrootfs.sh -o STAGE
#
# Base is built from the same tree the desktop release is built from
# (FreeLinX-desk: src/rootfs + kernel/bzImage + the stack packages), because
# that tree is the one that is kept current and passes check-nognu.  The old
# src/rootfs is not: Linux 6.6, GCC-built tools, GNU ncurses linked in.
#
# The desktop is taken out by package, not by search:
#
#   1. copy the desktop rootfs into STAGE (never edit the source tree)
#   2. register every stack package in STAGE's xpkg database, as the desktop
#      image build does
#   3. xpkg remove every package not in KEEP - each one takes its own files
#   4. delete the desktop files that no package owns (UNOWNED, below)
#   5. turn the greetd service into a plain console login
#   6. refuse the result if any ELF needs a library that is gone, or if
#      check-nognu finds GNU code in it
#
# Environment:
#   DESK      the FreeLinX-desk checkout   (default: ../Desktop-test)
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
DESK=${DESK:-$ROOT/Desktop-test}

STAGE=
while [ $# -gt 0 ]; do
	case $1 in
	-o) STAGE=$2; shift ;;
	*) printf 'usage: %s -o STAGE\n' "${0##*/}" >&2; exit 2 ;;
	esac
	shift
done
[ -n "$STAGE" ] || { printf 'usage: %s -o STAGE\n' "${0##*/}" >&2; exit 2; }

die() { printf 'mkrootfs: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

SRC=$DESK/src/rootfs
PKGS=$DESK/stack/work/pkgs
XPKG=$DESK/stack/work/sysroot/usr/bin/xpkg
MUSL_RUN=$DESK/stack/work/bin/musl-run
CHECK_NOGNU=$DESK/check-nognu.sh

[ -d "$SRC/usr/bin" ] || die "no desktop rootfs at $SRC"
[ -x "$XPKG" ] || die "no host xpkg at $XPKG (build the desktop stack first)"
[ -x "$MUSL_RUN" ] || die "no musl-run at $MUSL_RUN"
[ -f "$CHECK_NOGNU" ] || die "no check-nognu.sh at $CHECK_NOGNU"
ls "$PKGS"/*.xpkg >/dev/null 2>&1 || die "no packages in $PKGS"

# The rootfs is copied from the working tree, so uncommitted work would ship
# in an image no commit describes.  ALLOW_DIRTY=1 for a test build.
if [ "${ALLOW_DIRTY:-0}" != 1 ] && git -C "$DESK" rev-parse >/dev/null 2>&1; then
	dirty=$(git -C "$DESK" status --porcelain -- src/rootfs)
	[ -z "$dirty" ] || die "uncommitted changes in $SRC (ALLOW_DIRTY=1 to build anyway):
$dirty"
	say "==> desktop tree at $(git -C "$DESK" rev-parse --short HEAD)"
fi

xpkg() { NO_COLOR=1 "$MUSL_RUN" "$XPKG" --root "$STAGE" "$@"; }

# The packages base keeps.  Everything else in the stack is the desktop.
KEEP='
ca-certificates dbus expat flxnet libcxx libedit libelf libffi libmd libnl
libudev-zero libxml2 linux linux-firmware musl netbsd-curses nnn openssl pcre2
sqlite toybox tzdata wpa_supplicant xpkg zlib
'

# Desktop files that are in the desktop rootfs but in no package: configs,
# themes, launchers and a few apps that were copied in by hand.  Paths are
# relative to the rootfs; a missing one is skipped.
UNOWNED='
bin/foot bin/sxiv bin/xcalc bin/libnl bin/libX11-1.8.10 bin/libXau-1.0.11
bin/libxcb-1.17.0 bin/libXcursor-1.2.2 bin/libXdmcp-1.1.4 bin/libXext-1.3.6
bin/libXfixes-6.0.1 bin/libXft-2.3.8 bin/libXinerama-1.1.5 bin/libXrandr-1.5.4
bin/libXrender-0.9.11 bin/xcb-proto-1.17.0 bin/xorgproto-2024.1 bin/xtrans-1.6.0
usr/bin/dunst usr/bin/feh usr/bin/flx3dtest usr/bin/flxbg usr/bin/flxbrowser
usr/bin/flx-session usr/bin/flxupdates usr/bin/geany usr/bin/greetd
usr/bin/agreety usr/bin/tuigreet usr/bin/links usr/bin/mupdf usr/bin/pcmanfm
usr/bin/picom usr/bin/rxvt usr/bin/uxterm usr/bin/xterm usr/bin/x-www-browser
usr/lib/libatk-1.0.so.0.23809.1 usr/lib/openbox lib/python3.12
etc/X11 etc/xdg etc/greetd etc/fonts
root/.Xdefaults root/.config/openbox root/.themes home/live/.config
usr/share/X11 usr/share/icons usr/share/fonts usr/share/pixmaps
usr/share/applications usr/share/themes usr/share/backgrounds
usr/share/glib-2.0 usr/share/xsessions
var/lib/xkb var/lib/bluetooth var/lib/greetd
var/service/greetd var/service/bluetoothd var/service/flxupdates
'

# --- 1. copy -----------------------------------------------------------------
say "==> copying $SRC"
rm -rf "$STAGE"
mkdir -p "$STAGE"
(cd "$SRC" && tar -cf - .) | (cd "$STAGE" && tar -xf -)

# --- 2. register -------------------------------------------------------------
# ncurses and netsurf are transitional packages only, as in build-image.sh.
set -- $(ls "$PKGS"/*.xpkg | grep -v -E '/(ncurses|netsurf)-[0-9][^/]*\.xpkg$')
say "==> registering $# packages"
xpkg --quiet --no-scripts install "$@" >"$STAGE.register.log" 2>&1 || {
	tail -20 "$STAGE.register.log" >&2
	die 'registering packages failed'
}
find "$STAGE/etc" -name '*.xpkgnew' -type f -delete

# --- 3. remove the desktop packages ------------------------------------------
drop=
for p in $(xpkg list | awk '{ print $1 }'); do
	case " $(echo $KEEP) " in
	*" $p "*) ;;
	*) drop="$drop $p" ;;
	esac
done
say "==> removing $(echo $drop | wc -w) desktop packages"
# -f: removing a library and everything that needs it in one call is the point.
xpkg --quiet --no-scripts -f remove $drop >"$STAGE.remove.log" 2>&1 || {
	tail -20 "$STAGE.remove.log" >&2
	die 'removing the desktop packages failed'
}
for p in $(echo $KEEP); do
	xpkg info "$p" >/dev/null 2>&1 || die "kept package $p is not installed"
done

# --- 4. unowned desktop files ------------------------------------------------
say '==> removing unowned desktop files'
for p in $UNOWNED; do
	if [ -e "$STAGE/$p" ] || [ -L "$STAGE/$p" ]; then
		rm -rf "${STAGE:?}/$p"
	fi
done
# licenses of packages that are gone
for d in "$STAGE"/usr/share/licenses/*; do
	[ -d "$d" ] || continue
	n=${d##*/}
	case $n in SOURCES|netbsd|musl-fts|linux-pam|llvm-rt|elftoolchain) continue ;; esac
	xpkg info "$n" >/dev/null 2>&1 || rm -rf "$d"
done
rm -rf "$STAGE/var/cache/xpkg" "$STAGE/var/lib/xpkg/lock"
rm -f "$STAGE/etc/flx-desktop"

# --- 4b. what a console system needs that the desktop did not ship ----------
# All non-GNU ports packages (ISC, BSD, GPL-2 Linux tools); check-nognu below
# checks them like everything else.
#   mandoc    the man formatter; /usr/bin/man was a desktop help script
#   less      pager (BSD-2-Clause option of its dual licence)
#   iproute2  ip
#   lsof
ADD='mandoc less iproute2 lsof'
PORTS_PKGS=${PORTS_PKGS:-$ROOT/ports/packages}
rm -f "$STAGE/usr/bin/man"
set --
for p in $ADD; do
	f=$(ls "$PORTS_PKGS/$p"-[0-9]*.xpkg 2>/dev/null | sort -V | tail -1)
	[ -n "$f" ] || die "no $p package in $PORTS_PKGS"
	set -- "$@" "$f"
done
say "==> adding $ADD"
xpkg --quiet --no-scripts install "$@" >"$STAGE.add.log" 2>&1 || {
	tail -20 "$STAGE.add.log" >&2
	die 'adding the console packages failed'
}
ln -sf ../../bin/mandoc "$STAGE/usr/bin/man"
for n in apropos whatis; do
	[ -e "$STAGE/usr/bin/$n" ] || ln -sf ../../bin/mandoc "$STAGE/usr/bin/$n"
done
# vi is vim.  The nvi in the desktop tree (and the nvi2 port) calls
# getprogname() undeclared, so the pointer is truncated to int and it crashes
# on start; nvi2 also needs Berkeley db1, which nothing here builds.
rm -f "$STAGE/bin/nvi" "$STAGE/usr/bin/nvi" "$STAGE/bin/vi"
ln -s vim "$STAGE/bin/vi"

# Manual pages for the commands base ships, from the NetBSD source tree the
# userland was built from (bin, sbin, usr.bin, usr.sbin) and from the ports
# that carry their own (tmux, curl, OpenSSH).  The desktop shipped almost
# none, so `man ls` had nothing to show.
NETBSD_SRC=${NETBSD_SRC:-$ROOT/ports/build/work/netbsd-sh}
PORTS_WORK=$ROOT/ports/build/work
if [ -d "$NETBSD_SRC/usr.bin" ]; then
	n_man=0
	for d in bin sbin usr/bin usr/sbin; do
		for f in "$STAGE/$d"/*; do
			[ -e "$f" ] || continue
			c=${f##*/}
			# a toybox applet is not the NetBSD command of that name
			case $(readlink "$f" 2>/dev/null) in *toybox*) continue ;; esac
			for p in "$NETBSD_SRC"/bin/"$c"/"$c".[18] \
			    "$NETBSD_SRC"/sbin/"$c"/"$c".[18] \
			    "$NETBSD_SRC"/usr.bin/"$c"/"$c".[18] \
			    "$NETBSD_SRC"/usr.sbin/"$c"/"$c".[18] \
			    "$PORTS_WORK"/"$c"/"$c"-*/"$c".[18] \
			    "$PORTS_WORK"/"$c"/"$c"-*/docs/cmdline-opts/"$c".1 \
			    "$PORTS_WORK"/openssh/openssh-*/"$c".[18]; do
				[ -f "$p" ] || continue
				s=${p##*.}
				[ -e "$STAGE/usr/share/man/man$s/$c.$s" ] && break
				mkdir -p "$STAGE/usr/share/man/man$s"
				cp "$p" "$STAGE/usr/share/man/man$s/$c.$s"
				n_man=$((n_man + 1))
				break
			done
		done
	done
	say "    $n_man manual pages"
	# The index man reads first.  mandoc is static, so the host can run it;
	# invoked as makewhatis it builds mandoc.db.
	# (mandoc picks the mode from its name, so the link is called makewhatis)
	mkdir -p "$STAGE.tools"
	ln -sf "$STAGE/bin/mandoc" "$STAGE.tools/makewhatis"
	"$STAGE.tools/makewhatis" "$STAGE/usr/share/man" || die 'makewhatis failed'
	rm -rf "$STAGE.tools"
else
	say "    no NetBSD source tree at $NETBSD_SRC: manual pages not added"
fi

# which: the shell has `command -v`; scripts and people still type which.
printf '%s\n' '#!/bin/sh' \
	'# which NAME... - the path the shell would run for each NAME.' \
	'r=0' \
	'for n do' \
	'	p=$(command -v "$n") || { r=1; continue; }' \
	'	case $p in /*) printf "%s\n" "$p" ;; *) r=1 ;; esac' \
	'done' \
	'exit $r' >"$STAGE/usr/bin/which"
chmod 755 "$STAGE/usr/bin/which"

# --- 5. console login --------------------------------------------------------
# The banner, without the desktop's "right-click the desktop" line.
for f in etc/issue etc/motd; do
	[ -f "$STAGE/$f" ] || continue
	sed -i 's/^ Right-click the desktop for the menu\. Install to disk: flxinstall (as root)\.$/ Install to disk: flxinstall (as root).  Manuals: man <command>./' \
		"$STAGE/$f"
	grep -q 'desktop' "$STAGE/$f" && die "$f still talks about a desktop"
done

# What greetd's run script did when there was no desktop, and nothing else.
mkdir -p "$STAGE/var/service/console"
cat >"$STAGE/var/service/console/run" <<'EOF'
#!/bin/sh
# Console on tty1: a root shell on the live medium, a login prompt once
# installed (/etc/flx-installed).
if [ -e /etc/flx-installed ]; then
    exec /usr/bin/getty -l /usr/libexec/toybox/login 38400 tty1 linux
fi
# setsid -c: the tty becomes the shell's controlling terminal (job control,
# Ctrl-C).  runsv starts us in the service directory, so go home first.
cd /root 2>/dev/null || cd /
exec /usr/bin/setsid -c /bin/sh -l <>/dev/tty1 >&0 2>&1
EOF
chmod 755 "$STAGE/var/service/console/run"

# --- 6. checks ---------------------------------------------------------------
say '==> checking that every library is still there'
missing=$(find "$STAGE" -type f \( -perm -u+x -o -name '*.so*' \) | while read -r f; do
	head -c4 "$f" 2>/dev/null | grep -q ELF || continue
	readelf -d "$f" 2>/dev/null |
		sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | while read -r n; do
		[ -e "$STAGE/lib/$n" ] || [ -e "$STAGE/usr/lib/$n" ] ||
			printf '  %s needs %s\n' "${f#"$STAGE"/}" "$n"
	done
done || :)
[ -z "$missing" ] || die "libraries missing after the strip:
$missing"

say '==> checking for graphical programs'
gui=$(find "$STAGE" -type f | while read -r f; do
	head -c4 "$f" 2>/dev/null | grep -q ELF || continue
	grep -aqE 'XOpenDisplay|wl_display_connect|xcb_connect|gtk_init' "$f" &&
		printf '  %s\n' "${f#"$STAGE"/}"
done || :)
[ -z "$gui" ] || die "graphical programs left in the rootfs:
$gui"

say '==> check-nognu'
sh "$CHECK_NOGNU" "$STAGE" | tail -1
sh "$CHECK_NOGNU" "$STAGE" >/dev/null || die 'check-nognu failed'

say "==> base rootfs: $STAGE ($(du -sh "$STAGE" | cut -f1), $(xpkg list | wc -l) packages)"
