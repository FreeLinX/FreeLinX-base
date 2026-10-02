# FreeLinX base 1.0.8

The first release of FreeLinX base: FreeLinX with no desktop. You get a shell
on the console, and `xpkg` for everything else.

```
freelinx-base-x86_64.iso   278 MB   BIOS and UEFI
sha256  faefb97e6762ef3fb6909dab422990a6a2042a586c3e39202a5e7f6ab5a0be5c
```

## What it is

It is the system of the FreeLinX desktop release with the desktop taken out:

- Linux 6.18.54 LTS, built with clang
- musl, the NetBSD userland, runit, mdevd
- OpenSSL 3.5, OpenSSH 10.5, curl 8.22, git, tmux, htop, nnn, vim (also `vi`)
- dhcpcd, wpa_supplicant and `flxwifi` for WiFi
- `man` (mandoc) with about 200 manual pages, `less`, `ip`, `lsof`
- `xpkg`, with the signed repository of 425 packages

No GNU code. Every one of the 619 programs and libraries in the image passes
`check-nognu`. The build refuses to produce an image when one does not.

## Installing

Boot the ISO. You get a root shell on tty1. Run:

```sh
flxinstall
```

It asks for the language, keyboard, time zone, hostname, root password, a user
and WiFi, and then erases the disk you choose. The installed system has:

- the system image on the ESP, booted by Limine on BIOS and UEFI
- `/usr /etc /var /root /bin /sbin /lib` on the FLX_SYS partition, so what you
  install and configure survives a reboot
- `/home` on its own partition
- a login prompt on tty1

To upgrade later, boot a newer ISO and run `flxupgrade`.

## Fixed on the way

These fixes are also in the desktop:

- **The console was black on most graphics cards.** It worked only where a
  built-in driver took the screen (Intel, virtio). On AMD, NVIDIA and plain VGA
  the kernel had no console driver until a GPU module loaded. Linux now uses the
  framebuffer the firmware hands over (`simpledrm`), on BIOS and on UEFI.
- **The text installer did not work interactively.** Its menus were printed
  into the variable that should hold the answer: nothing was shown, and the
  install stopped at the first question. The hostname question was always
  skipped, so every system was called FreeLinX.
- **WiFi passwords were visible to every user.** They were passed to
  `wpa_cli` on its command line, which `ps` shows. They now go into the
  supplicant's own config file, readable by root only. Saved networks reconnect
  at boot, and passwords with quotes, spaces or backslashes work.
- The prompt shows the real hostname.

## Tested

In QEMU/KVM, 2 GB RAM:

- **BIOS:** live boot, `flxinstall` with presets, boot from the disk, login,
  `xpkg install` over HTTPS, a file and a package still there after reboot.
- **UEFI (OVMF):** live boot, `flxinstall` answered by hand with no presets,
  boot from the disk, login as root and as the user, `doas`.
- **Console:** framebuffer console with bochs VGA, and with `simpledrm` alone
  (`ramfb`, no GPU driver).
- **WiFi:** `mac80211_hwsim` + `hostapd`, WPA2, an SSID and a passphrase with
  quotes, a space and a backslash.

Not tested yet: real hardware.

## Known limits

- Building base needs a built FreeLinX-desk tree and the ports work tree, which
  are not in git. It cannot yet be built from a fresh clone.
- `vi` is vim. The nvi port crashes on start and needs Berkeley db1 to be
  rebuilt.
- `xsetup`, the older installer in this repository, is not on the ISO. See the
  README.
