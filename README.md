# FreeLinX base

The two non-graphical FreeLinX images, and the installer that puts one of them
on a disk.

| Image | What it is |
|---|---|
| `out/base.iso` | the installer: the whole system plus `/installer/xsetup` |
| `out/base (boot only).iso` | rescue: the system with no installer on it |

Both boot on BIOS and on UEFI. Build and hand-test instructions are in
[RELEASE.md](RELEASE.md).

Base is a shell, not a desktop. There is no X server, no window manager, no X
client and no browser in the image, and nothing graphical is started at boot —
the way Ubuntu Server, Fedora minimal and Arch without a desktop are shells
rather than installations of a window manager with a terminal emulator.

## The installer

`xsetup` runs thirteen steps and records each one, so an interrupted install
resumes without asking again about something already answered.

```
setup-keymap  setup-hostname  setup-interfaces  setup-passwd  setup-timezone
setup-proxy   setup-ntp       setup-apkrepos    setup-user    setup-sshd
setup-disk    setup-lbu       setup-apkcache
```

```sh
xsetup                       # every step not done yet, in order
xsetup --list                # the steps
xsetup --status              # which are done
xsetup --reset NAME          # forget one step and run it again
xsetup setup-disk            # run one step by name
```

`setup-disk` is the irreversible one. It erases the disk it is given, and asks
you to type `yes` in as many words before it will.

*RIGHT NOW DONT WORK*


## Tests

| Suite | What it covers |
|---|---|
| `test-ui.sh` | `lib/ui.sh`: the menus, the prompts, their edge cases |
| `test-setup-disk.sh` | the disk step's conversation — geometry, guards, dry runs |
| `test-destructive.sh` | the installer's commands, run against image files |
| `test-destructive-qemu.sh` | a real install onto a real disk, in a VM |
| `test-live-boot.sh` | boots the shipped ISO and asks the running system questions |

```
sh test-ui.sh                # 56 passed, 0 failed
sh test-setup-disk.sh        # 39 passed, 0 failed
sh test-destructive.sh       # 58 passed, 0 failed
```

The last two need QEMU and take minutes.

A test here is expected to fail when the code it covers is put back. Several of
them were written that way: each was checked by breaking the thing it describes
and confirming the suite caught it, because a check that cannot find what it
looks for reports it absent, which reads exactly like the bug it exists to catch.

## What has been fixed

Twenty commits, oldest first. The ones that changed behaviour for anybody
running the installer:

**The images**

- The kernel and initramfs now live on the boot chain on the ESP, and the suite
  tests what the code does rather than what it claims.
- `base.iso` was 226 MB with a desktop in it and 113 MB without. 413 paths are
  removed by `scripts/strip-desktop.sh`, which runs as part of every build, so
  the desktop cannot come back by being forgotten.
- Data mode was rewritten: one partition, no boot chain, no system, labelled
  `FREELINX_VAR`, which is the label `/init` mounts at `/var`.
- A console that works. Limine refused the framebuffer handover, the kernel fell
  back to a dummy console, and tty1 was discarded. Two causes, both in
  `limine.conf`: the key is `textmode`, not `text_mode`, and it has to be inside
  the menu entry. There is no framebuffer console in the kernel config, and that
  is deliberate — with no X client nothing loads a DRM driver, so vgacon binds
  the console alone and tty1 works.

**The installer**

- `xsetup` read its own step names as the answers to its questions. Every step
  ran and each was answered with the name of the step after it.
- A sourced step that finished with `exit` ended the whole installer. It had
  printed its line and said everything was fine, then dropped the operator at the
  shell with steps 7 to 13 never run and nothing marked done.
- `ask_yes` ignored its default: an empty answer took yes whatever the default
  was, in five of its eight calls.
- The timezone menu returned a region name as another region's label. A single
  zone region — `UCT`, `Zulu`, `W-SU` — ended the installer.
- `sort` was handed a file rather than a pipe. This system's `sort` opens
  `/dev/stdin`, which is unreachable; `cut`, `grep`, `sed`, `awk`, `head`,
  `tail`, `tr`, `wc`, `uniq` and `comm` do not.
- `setup-user` passed `-m` to `flxuseradd`, which has no `-m`. That is
  `adduser(8)`'s flag. The step died on every install, having created nothing,
  with the usage printed directly above the error where it read like a paragraph
  and scrolled past.
- A user name in upper case ended the installer. It is folded to lower case now
  and the fold is printed, because lower case is right to store and not a reason
  to discard what somebody typed.
- `setup-disk` could not find the medium it was running from. It searched two
  levels up from `$(dirname "$0")`, but a step is *sourced*, so `$0` is the
  dispatcher's path and two levels up from `/media/flx/installer/xsetup` is
  `/media`. Every lookup missed a mounted, readable medium.
- Every menu whose options filled the last row killed the installer. `xsetup`
  runs `set -eu`, and the subshell that prints a menu ended with
  `[ "$_col" -ne 0 ] && printf '\n' >&2`, which returns 1 when the count is a
  multiple of the row width. Five options worked, six did not, twenty-four did
  not. The menu printed and the prompt never did, so whatever was typed next went
  to the shell.

## Known gaps

Not finished, and not pretended to be:

- **UEFI has no on-screen console.** Limine's `textmode` is BIOS-only; UEFI
  always reports `VIDEO_TYPE_EFI`. The serial console works and the installer is
  usable over it, but the screen stays black after Limine.
- **Arrow keys do nothing.** A Linux VT does not send escape sequences for them.
  Answering an installer prompt needs a shell with terminfo line editing and a
  `TERM` that defines `kcuu1`.
- **The keymap choice is recorded, not applied.** Linux removed `KDSETKEYMAP`
  and `struct kbentry`, so there is no interface for a running program to
  re-lay-out a text console. The step says so rather than appearing to change it.
- **Data mode has never had a clean QEMU run.** Its logic is proven in isolation
  only.
- **`/proc/self/fd` is permission-denied in the guest.** This is why the `sort`
  bug above existed and it is worked around rather than fixed; other programs
  may depend on it.
- **The port set is incomplete.** Seven ports are missing and five fail to build.
  That is a separate pass and it is not done.

## Licence

BSD-2-Clause.
