# Releasing base

## Build

```sh
sh build-base.sh                 # -> out/freelinx-base-x86_64.iso (+ .sha256)
```

It takes about two minutes. It needs `../Desktop-test` (FreeLinX-desk) to be
built: `src/rootfs`, `kernel/bzImage`, `stack/work/pkgs`, the host xpkg in
`stack/work/sysroot`. It also needs `../ports/packages`. Base is cut from the
same tree as the desktop release, so build and tag the desktop first.

## Test in QEMU

```sh
SERIAL=1 OUT=/tmp/base-serial.iso sh build-base.sh
qemu-img create -f qcow2 disk.qcow2 12G
qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 \
  -drive file=disk.qcow2,if=virtio,format=qcow2 \
  -cdrom /tmp/base-serial.iso -boot d -vga std \
  -serial file:ttyS0.log -serial unix:sh.sock,server,nowait \
  -nic user,model=virtio-net-pci
```

ttyS0 carries the kernel log. ttyS1 (`sh.sock`) is a root shell on the live
medium and a login prompt on an installed system. To install without questions:

```sh
printf '%s\n' TZ_STR=UTC HOSTNAME=t ROOTPW=pw USERNAME=tester USERPW=pw > /root/preset
flxinstall -p /root/preset -y /dev/vda < /dev/null   # unset answers default to no
```

Then boot the disk (`-boot c`, no `-cdrom`) and check the following:

- `FLX_SYS persistent system engaged` is in the log.
- root can log in.
- `cat /sys/class/vtconsole/vtcon1/name` says `frame buffer device`. If it only
  says `dummy device`, the kernel lost `CONFIG_SYSFB_SIMPLEFB` and the screen is
  black.
- A file in `/root` and an `xpkg install`ed package survive `reboot`.

## Publish

1. Put the version in `VERSION`. It goes into `/etc/os-release`, the banner
   and the boot menu.
2. Commit, tag `v<VERSION>`, push.
3. Build from a clean FreeLinX-desk tree (`mkrootfs.sh` refuses uncommitted
   changes there) and test as above.
4. `gh release create v<VERSION> out/freelinx-base-x86_64.iso
   out/freelinx-base-x86_64.iso.sha256 -R FreeLinX/FreeLinX-base
   -F RELEASE-NOTES.md`
