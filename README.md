# FreeLinX base

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
  `less`, `ip` (iproute2), `lsof`.
- **Installing:** `flxinstall` puts the system on a disk, and `flxupgrade`
  upgrades it from a newer ISO.

Anything else comes from `xpkg install <name>`. The repository has 425 packages.

## Installing

Boot the ISO. You get a root shell on tty1. Then:

```sh
flxinstall
```

This is the desktop's installer. On an image with no desktop it installs a
console system without asking which kind you want. The disk is laid out as:

| Partition | Contents |
|---|---|
| ESP (1 GB) | the kernel and the system image, booted by Limine on BIOS and UEFI |
| BIOS boot | Limine's BIOS stage |
| FLX_SYS | persistent `/usr /etc /var /root /bin /sbin /lib`, so packages and settings survive a reboot |
| FLX_HOME | `/home` |

The installed system asks for a login on tty1, and on ttyS1 for a serial console.

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

In QEMU, KVM, std VGA, 2 GB, on 2026-10-02:

- The live ISO boots to a framebuffer console, and dhcpcd gets an address.
- `flxinstall` with a preset installs to a 12 GB virtio disk.
- The installed disk boots, FLX_SYS engages (7 trees bound), and the login works.
- `xpkg update` and `xpkg install jq` fetch over HTTPS from the signed repository.
- A file in `/root` and the installed package are still there after a reboot.

Not tested: real hardware.

## Not shipped any more

`xsetup` (with `xsetup.d/`, `lib/ui.sh` and the `test-*.sh` suites that test it)
was written for the old `src/rootfs`. Its disk mode copies the system to an ext4
root and boots it with `root=UUID=`, but FreeLinX's `/init` never switches root:
the system always runs from the initramfs. So it installed a disk that booted
back into the unchanged live system. Its data mode relies on a `FREELINX_VAR`
filesystem that `/init` does not mount. It is kept here and not put on the ISO.

## Licence

BSD-2-Clause.
