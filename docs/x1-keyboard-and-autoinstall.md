# X1: external keyboard failed too — and the keyboard-free way forward

## What the second failure tells us

A Kensington USB keyboard failing **identically** to the internal one rules out my first diagnosis.
Two unrelated keyboards do not both have exotic report descriptors — a Kensington presents a
bog-standard boot-protocol descriptor that illumos parses on every other machine.

Decisive additional fact: **the keyboard worked at the `ok` prompt.** You typed `smap`, `memmap`,
`lsdev` and `ls` there. So the hardware is fine and the firmware path is fine; input breaks only once
illumos takes over with its own USB stack. **The common factor is our media, not your keyboards.**

That also means my "plug in an external keyboard" advice was a workaround for the wrong cause. It was
worth 30 seconds to try, but it was not diagnosis.

## What is verified about the media so far

* `hid` is present and bound correctly — `/etc/driver_aliases` has `hid "usbif,class3"` (the USB HID
  class), and `hid1` appears in the device tree.
* `usba` and `xhci` work — the USB stick was read and `blkdev0` came online.
* `/etc/iu.ap` is copied from the build host and contains the expected autopush lines.

But note what `/etc/name_to_major` on the build host shows:

| module | `name_to_major` | `driver_aliases` |
|---|---|---|
| `usbkbm` | **0** | 0 |
| `kbtrans` | **0** | 0 |
| `conskbd` | 1 | 0 |
| `hid` | 1 | 1 |

`usbkbm` and `kbtrans` are STREAMS **modules** (not drivers), so their absence from `name_to_major` is
expected — but it means they must be present as files under `/kernel/strmod/` and reachable, and the
media build never explicitly stages them. **That is the leading suspect**: the keyboard input chain is

```
usb kbd -> hid -> usbkbm -> kbtrans -> conskbd -> wc/console
```

and a missing STREAMS module in the middle would break every keyboard identically, exactly as observed.
The `ttymon: open /dev/sad/user failed` message points the same way — `sad(7D)` is the STREAMS
autopush administrative device.

## The keyboard-free path: `/etc/solnix-autoinstall`

`oi-make-livecd.sh:870-896` already implements a hands-off install. If `/etc/solnix-autoinstall`
exists on the media, the `site/solnix-live` SMF service will:

1. run `devfsadm` and print `[solnix] disks visible:`
2. read the target disk from that file, or **auto-pick** the first `c*t*d0s0` if it says `auto`
3. print `[solnix] AUTO-INSTALL to <disk>` and run `format </dev/null`
4. run `solnix-install`, printing `SOLNIX_AUTOINSTALL_RESULT: DONE` or `FAIL rc=<n>`

All of that goes to the console, so **you get a full diagnostic transcript with no keystrokes.**

## ⚠️ But not yet — ZFS is broken on this media

The same boot showed:

```
internal error: failed to initialize ZFS
svc:/system/filesystem/local:default: WARNING: /usr/sbin/zfs mount -a failed: exit status 1
```

`solnix-install` needs ZFS to create `rpool`. Auto-installing now would very likely fail *after* it
has begun writing to your 1 TB SSD. **Both faults get fixed in one media rebuild first.**

## What the next image will carry

1. the STREAMS keyboard chain (`usbkbm`, `kbtrans`, `conskbd`) explicitly staged and verified present
2. `/dev/sad` created so `ttymon` and autopush work
3. the ZFS userland closure fixed so `libzfs` initialises
4. `/etc/solnix-autoinstall` **not** enabled by default — you opt in by creating the file, so nothing
   ever touches a disk unasked

## Two-for-two on QEMU being easier than the target

QEMU gives us a **PS/2** keyboard (`kb80420 is /pci@0,0/isa@1f/i8042@1,60/keyboard@0`), which binds
with no HID parsing and no STREAMS keyboard chain. The X1 has no PS/2 controller. Combined with the
820 MiB staging allocation that only fails on fragmented real firmware, that is twice the emulator was
systematically more permissive than the target in exactly the dimension that mattered.

**Consequence for how we test:** a QEMU pass is necessary but not sufficient, and the remaining
untested-on-hardware list (graphics, wifi, suspend) should be assumed broken until a real boot says
otherwise.
