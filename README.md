# FreeLinX base

Current release: **1.0.11** ([release notes](RELEASE-NOTES.md)).

FreeLinX without a desktop: a shell on the console, `xpkg` for everything else.

```
out/freelinx-base-x86_64.iso     278 MB, boots on BIOS and UEFI
```

Base is the desktop release's system with the desktop taken out. It has the same
Linux 6.18 kernel, the same NetBSD userland, the same OpenSSL, OpenSSH and xpkg,
and it passes the same no-GNU gate (`check-nognu.sh`, 0 failing).

## What is on it

25 packages from the desktop stack plus four console ports, with no X11, GTK,
Mesa or fonts:

- **System:** runit, mdevd, dhcpcd, wpa_supplicant and `flxwifi`, ntpd, dbus,
  doas, OpenSSH (ssh and sshd), curl, git, tmux, htop, nnn, vim (also as `vi`),
  bc, e2fsprogs, dosfstools.
- **Added for the console:** `man` (mandoc, with about 200 NetBSD manual pages),
  `less`, `ip` (iproute2), `lsof`, and `mksh` as the login shell (arrow keys,
  history, Tab completion). `/bin/sh` stays the NetBSD sh for scripts.
- **A C compiler:** `cc` (tcc) with the musl and kernel headers.
- **Installing:** `xsetup` puts the system on a disk, and `flxupgrade`
  upgrades it from a newer ISO.

Anything else comes from `xpkg install <name>`. The repository has 425 packages.

## Installing

Boot the ISO. You get a root shell on tty1. Run:

```sh
xsetup
```

`xsetup` is a manual installer: thirteen steps, one question at a time, and
each step is recorded, so an install that is interrupted carries on where it
stopped.

```
setup-keymap      setup-hostname    setup-interfaces  setup-passwd
setup-timezone    setup-proxy       setup-ntp         setup-apkrepos
setup-user        setup-sshd        setup-disk        setup-lbu
setup-apkcache
```

```sh
xsetup                  # every step not done yet, in order
xsetup --list           # the steps
xsetup --status         # which are done
xsetup --reset NAME     # forget one step, so it runs again
xsetup setup-sshd       # run one step on its own
```

`setup-disk` is the step that writes to a disk. It asks whether to run from RAM
(nothing is written) or to install, then asks which disk, and it erases nothing
until you type `yes`. An install lays the disk out as:

| Partition | Contents |
|---|---|
| ESP (1 GB) | the kernel and the system image, booted by Limine on BIOS and UEFI |
| BIOS boot | Limine's BIOS stage |
| FLX_SYS | persistent `/usr /etc /var /root /bin /sbin /lib`, so packages and settings survive a reboot |
| FLX_HOME | `/home` |

The system image is the running system with everything the earlier steps set,
so the installed system starts with the same keymap, hostname, network, users,
time zone and services. It asks for a login on tty1, and on ttyS1 for a serial
console.

## Building

```sh
sh build-base.sh
```

It needs a built FreeLinX-desk checkout next to this one (`../Desktop-test`:
`src/rootfs`, `kernel/bzImage` and the stack packages) and `../ports`. It does
the following:

1. `scripts/mkrootfs.sh` copies the desktop rootfs and registers every stack
   package. It runs `xpkg remove` on the 100 desktop packages, so each takes its
   own files, and deletes the desktop files no package owns. It adds the console
   ports and the manual pages. It fails if any program needs a library that is
   gone, if any graphical program is left, or if `check-nognu` finds anything.
2. Firmware from `firmware-<kver>.tar.xz`, if it is there.
3. The system is packed as one xz initramfs and put on a Limine ISO labelled
   `FREELINX_LIVE`, which is the label `flxupgrade` looks for.

`SERIAL=1 sh build-base.sh` also puts the console on ttyS0, for testing in QEMU.

## Tested

In QEMU/KVM with 2 GB RAM, for 1.0.8. The details are in
[RELEASE-NOTES.md](RELEASE-NOTES.md).

- **BIOS:** live boot, an install with presets, boot from the disk, login,
  `xpkg install` over HTTPS, and a reboot that keeps a file and a package.
- **UEFI (OVMF):** an install answered by hand with no presets, boot from the
  disk, login as root and as the user.
- **Console:** a framebuffer console with bochs VGA, and with `simpledrm` alone.
- **WiFi:** WPA2 against `mac80211_hwsim` + `hostapd`.

Not tested yet: real hardware.

## Tests

| Suite | What it covers |
|---|---|
| `test-ui.sh` | `lib/ui.sh`: the menus, the prompts, their edge cases |
| `test-setup-disk.sh` | the disk step's conversation: layout, sizes, guards, dry runs |
| `test-destructive.sh` | what an install does to bytes, with the image's own tools on image files |
| `test-xsetup-qemu.sh` | all 13 steps in a VM, then boots the disk and checks the result |

```sh
sh test-ui.sh && sh test-setup-disk.sh && sh test-destructive.sh
SERIAL=1 OUT=out/freelinx-base-serial.iso sh build-base.sh
sh test-xsetup-qemu.sh            # BIOS
sh test-xsetup-qemu.sh --uefi     # UEFI (OVMF)
```

## Licence

BSD-2-Clause.
